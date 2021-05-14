FROM php:7.0.33-cli-alpine

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

RUN install-php-extensions @composer-2.0.2 gd memcached gettext imagick mcrypt mysqli redis pdo_mysql opcache exif bcmath soap sockets timezonedb zip snmp bz2


ENTRYPOINT ["docker-php-entrypoint"]
CMD ["php", "-a"]