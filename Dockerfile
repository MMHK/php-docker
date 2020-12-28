FROM nginx:alpine

WORKDIR /app

COPY . .

RUN mkdir -p /etc/nginx/templates \
    && cp /app/default.conf.template /etc/nginx/templates/default.conf.template