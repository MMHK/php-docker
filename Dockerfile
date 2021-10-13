FROM php:8-fpm-alpine

COPY --from=mlocati/php-extension-installer /usr/bin/install-php-extensions /usr/local/bin/

ENV WWW_UID=1000
ENV WWW_GID=1000
ENV OPCACHE_JIT=tracing
ENV OPCACHE_JIT_BUFFER=128M

RUN install-php-extensions @composer gd memcached gettext imagick mcrypt mysqli redis pdo_mysql opcache exif bcmath soap sockets timezonedb zip snmp bz2 \
 && apk --no-cache add shadow \
 && sed -i -e "s/;php_admin_value\[error_log\] = \/var\/log\/fpm-php\.www\.log/php_admin_value[error_log]=\/proc\/self\/fd\/2/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;chdir =/chdir =/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;rlimit_files = 1024/rlimit_files = 102400/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/pm.max_children = 5/pm.max_children = 500/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/pm.max_spare_servers = 3/pm.max_spare_servers = 500/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;pm.max_requests = 500/pm.max_requests = 5/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;php_admin_flag\[log_errors\]/php_admin_flag\[log_errors\]/g" /usr/local/etc/php-fpm.d/*.conf \
 && echo -e "php_admin_value[opcache.jit]=${OPCACHE_JIT}\n" >> /usr/local/etc/php-fpm.d/www.conf \
 && echo -e "php_admin_value[opcache.jit_buffer_size]=${OPCACHE_JIT_BUFFER}\n" >> /usr/local/etc/php-fpm.d/www.conf \
 && usermod -u $WWW_UID www-data \
 && groupmod -g $WWW_GID www-data


EXPOSE 9000
CMD ["php-fpm"]