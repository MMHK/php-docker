# PHP Docker

[![dockeri.co](https://dockeri.co/image/mmhk/php-docker)](https://hub.docker.com/r/mmhk/php-docker)

![GitHub](https://img.shields.io/github/license/mmhk/mmfm)

适用于容器化的PHP执行环境, 集成 `nginx` web server

### 已安装扩展

|||
|-|-|
|composer||
|gd||
|memcached||
|gettext||
|imagick||
|mcrypt||
|mysqli||
|redis||
|pdo_mysql||
|opcache||
|exif||
|bcmath||
|soap||
|sockets||
|timezonedb||
|zip||
|snmp||
|bz2||


### RUN

```
cd [你的项目public目录]
wget "https://raw.githubusercontent.com/MMHK/php-docker/8-fpm-nginx/docker-compose.yml"
docker-compose up
```