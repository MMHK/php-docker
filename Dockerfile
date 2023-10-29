FROM php:7.0-fpm-alpine

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

ENV WWW_UID=1000
ENV WWW_GID=1000
ENV TZ=Asia/Hong_Kong

## add laster ca cert
ADD cacert.ini /usr/local/etc/php/conf.d/docker-php-ext-openssl.ini
RUN apk --no-cache add ca-certificates \
  && curl -sSLk https://curl.se/ca/cacert.pem -o /usr/local/share/ca-certificates/curl-ca.crt \
  && chmod 644 /usr/local/share/ca-certificates/curl-ca.crt \
  && update-ca-certificates

# fix work iconv library with alpine
RUN apk add --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/v3.10/community/ --allow-untrusted gnu-libiconv
ENV LD_PRELOAD /usr/lib/preloadable_libiconv.so


# base layer
RUN install-php-extensions @composer gd php-memcached-dev/php-memcached@v3.2.0 phpredis/phpredis@3.1.1 \
 gettext mcrypt mysqli pdo_mysql opcache exif bcmath soap sockets \
 php/pecl-datetime-timezonedb@RELEASE_2023_3 zip snmp bz2 iconv \
 Imagick/imagick@3.7.0 \
 && apk --no-cache add shadow tzdata


# config layer
RUN sed -i -e "s/;php_admin_value\[error_log\] = \/var\/log\/fpm-php\.www\.log/php_admin_value[error_log]=\/proc\/self\/fd\/2/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;chdir =/chdir =/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;rlimit_files = 1024/rlimit_files = 102400/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/pm.max_children = 5/pm.max_children = 32/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/pm.start_servers = 2/pm.start_servers = 6/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/pm.min_spare_servers = 1/pm.min_spare_servers = 2/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/pm.max_spare_servers = 3/pm.max_spare_servers = 10/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;pm.max_requests = 500/pm.max_requests = 5/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;php_admin_flag\[log_errors\]/php_admin_flag\[log_errors\]/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;php_admin_value\[memory_limit\] = 32M/php_admin_value\[memory_limit\] = 256M/g" /usr/local/etc/php-fpm.d/*.conf \
 && usermod -u $WWW_UID www-data \
 && groupmod -g $WWW_GID www-data

EXPOSE 9000

ADD entrypoint.sh /entrypoint.sh
ADD file-upload.conf /usr/local/etc/php-fpm.d/file-upload.conf

ENTRYPOINT ["/entrypoint.sh"]
CMD ["php-fpm"]