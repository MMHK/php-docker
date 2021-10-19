FROM nginx:alpine

ENV WS_PROXY_HOST="http://php:5343" \
   FPM_HOST="php:9000"

WORKDIR /app

COPY . .

RUN mkdir -p /etc/nginx/templates \
    && cp /app/default.conf.template /etc/nginx/templates/default.conf.template