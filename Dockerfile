FROM caddy:2.6.2-builder-alpine AS builder

RUN go env -w GOPROXY=https://goproxy.cn,direct \
  && xcaddy build \
    --with clevergo.tech/caddy-dnspodcn \
    --with github.com/imgk/caddy-trojan

FROM caddy:2.6.2-alpine

ENV WWW_UID=1000
ENV WWW_GID=1000

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY errors.html /etc/caddy/error/error.html
COPY Caddyfile /etc/caddy/Caddyfile

RUN apk --no-cache add shadow tzdata \
  && groupmod -g $WWW_GID www-data \
  && useradd -u $WWW_UID -g $WWW_GID www-data \
  && umask 0000

USER www-data:www-data