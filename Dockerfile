FROM php:8-fpm-alpine

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

ENV WWW_UID=1000
ENV WWW_GID=1000

RUN install-php-extensions @composer-2.0.2 gd memcached gettext imagick mcrypt mysqli redis pdo_mysql opcache exif bcmath soap sockets timezonedb zip snmp bz2 \
 && apk --no-cache add shadow \
 && usermod -u $WWW_UID www-data \
 && groupmod -g $WWW_GID www-data


EXPOSE 9000
CMD ["php-fpm"]