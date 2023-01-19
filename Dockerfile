FROM mmhk/php-docker:7.2-fpm

USER root

RUN apk add --no-cache tzdata

USER www-data:www-data