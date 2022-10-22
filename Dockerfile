FROM caddy:2.6.2-alpine

ENV WWW_UID=1000
ENV WWW_GID=1000

COPY errors.html /etc/caddy/error/error.html
COPY Caddyfile /etc/caddy/Caddyfile

RUN apk --no-cache add shadow \
  && groupmod -g $WWW_GID www-data \
  && useradd -u $WWW_UID -g $WWW_GID www-data \
  && umask 0000
  
USER www-data:www-data