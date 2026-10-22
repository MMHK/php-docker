FROM php:8.3.36-fpm-bookworm

ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/

ENV TZ=Asia/Hong_Kong
ENV WWW_UID=1000
ENV WWW_GID=1000

# base layer
# pecl.php.net 偶发 HTTP 500（下载失败），这里加重试循环（最多 5 次，间隔 15s）
RUN apt-get update && apt-get install -y tzdata \
 && { i=0; until install-php-extensions @composer gd gmp memcached gettext imagick mcrypt mysqli redis pdo_mysql pdo_pgsql pgsql zstd opcache exif bcmath soap sockets timezonedb zip snmp bz2 shmop ffi; do \
      i=$((i+1)); [ $i -ge 5 ] && exit 1; echo "install attempt $i failed, retrying in 15s"; sleep 15; \
    done; } \
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
# 防止 Windows 环境下 entrypoint.sh 出现 CRLF 导致 "exec format error"
RUN chmod +x /entrypoint.sh \
 && sed -i 's/\r$//' /entrypoint.sh

EXPOSE 9000

USER www-data:www-data
ENTRYPOINT ["/entrypoint.sh"]

CMD ["php-fpm"]