FROM caddy:2.6.2-builder-alpine AS builder

ENV GORPOXY=direct

WORKDIR /app

COPY main.go /app/main.go
COPY go.mod /app/go.mod
COPY go.sum /app/go.sum
COPY vendor /app/vendor

RUN go env \
   && go build -ldflags="-s -w" -o  /usr/bin/caddy .

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
