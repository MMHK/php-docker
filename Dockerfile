FROM mmhk/php-docker:8.0-fpm

USER root

# base layer
RUN install-php-extensions gmp

RUN install-php-extensions gmp


EXPOSE 9000

USER www-data:www-data

ENTRYPOINT ['/entrypoint.sh']

CMD ["php-fpm"]