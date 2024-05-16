FROM mmhk/php-docker:7.4-fpm

USER root

# base layer
RUN install-php-extensions pgsql pdo pdo_pgsql

USER www-data:www-data

EXPOSE 9000

CMD ["php-fpm"]