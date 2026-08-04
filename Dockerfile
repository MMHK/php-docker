FROM php:8.1-fpm-bookworm

ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

ENV TZ=Asia/Hong_Kong
ENV WWW_UID=1000
ENV WWW_GID=1000

# base layer
RUN apt-get update && apt-get install -y tzdata \
 && install-php-extensions @composer gd gmp memcached gettext imagick mcrypt mysqli redis pdo_mysql pdo_pgsql pgsql zstd opcache exif bcmath soap sockets timezonedb zip snmp bz2 shmop ffi \
 && rm -rf /var/lib/apt/lists/*

RUN sed -i -e "s/;php_admin_value\[error_log\] = \/var\/log\/fpm-php\.www\.log/php_admin_value[error_log]=\/proc\/self\/fd\/2/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;chdir =/chdir =/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;rlimit_files = 1024/rlimit_files = 102400/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/pm.max_children = 5/pm.max_children = 32/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/pm.max_spare_servers = 3/pm.max_spare_servers = 32/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;pm.max_requests = 500/pm.max_requests = 5/g" /usr/local/etc/php-fpm.d/*.conf \
 && sed -i -e "s/;php_admin_flag\[log_errors\]/php_admin_flag\[log_errors\]/g" /usr/local/etc/php-fpm.d/*.conf \
 && usermod -u $WWW_UID www-data \
 && groupmod -g $WWW_GID www-data


COPY file-upload.conf /usr/local/etc/php-fpm.d/file-upload.conf
COPY opcache.ini /usr/local/etc/php/conf.d/opcache.ini
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 9000

USER www-data:www-data
ENTRYPOINT ["/entrypoint.sh"]

CMD ["php-fpm"]
