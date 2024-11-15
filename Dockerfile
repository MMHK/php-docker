FROM caddy:2.6.2-builder-alpine AS builder

ENV GORPOXY=direct

WORKDIR /app

RUN xcaddy build \
  --output /usr/bin/caddy \
  --with github.com/mmhk/caddy-dnspodcn \
  --with github.com/corazawaf/coraza-caddy

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

ENV TZ=Asia/Hong_Kong

USER www-data:www-data
