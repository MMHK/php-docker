FROM php:7.0-fpm-alpine

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

ENV WWW_UID=1000
ENV WWW_GID=1000

# fix work iconv library with alpine
RUN apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/community/ --allow-untrusted gnu-libiconv
ENV LD_PRELOAD /usr/lib/preloadable_libiconv.so php

RUN install-php-extensions @composer gd memcached gettext imagick mcrypt mysqli redis pdo_mysql opcache exif bcmath soap sockets timezonedb zip snmp bz2 iconv \
 && apk --no-cache add shadow \
 && sed -i -e "s/;php_admin_value\[error_log\] = \/var\/log\/fpm-php\.www\.log/php_admin_value[error_log]=\/proc\/self\/fd\/2/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;chdir =/chdir =/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;rlimit_files = 1024/rlimit_files = 102400/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;pm.max_requests = 500/pm.max_requests = 5/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;php_admin_flag\[log_errors\]/php_admin_flag\[log_errors\]/g" /usr/local/etc/php-fpm.d/*.conf \
 && usermod -u $WWW_UID www-data \
 && groupmod -g $WWW_GID www-data

USER www-data:www-data

EXPOSE 9000
COPY entrypoint.sh /entrypoint.sh
COPY file-upload.conf /usr/local/etc/php-fpm.d/file-upload.conf

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]