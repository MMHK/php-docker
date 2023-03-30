# PHP-Docker 

适用于容器化的PHP执行环境

### Environment

|ENV|remark|default value|
|-|-|-|
|WWW_UID|www-data(容器自带fpm执行账户)账户的UID|1000|
|WWW_GID|www-data(容器自带fpm执行账户)账户的GID|1000|
|OPCACHE_JIT|对应php.ini `opcache.jit`|tracing|
|OPCACHE_JIT_BUFFER|对应php.ini `opcache.jit_buffer_size`|128M|

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
docker run -d --name php-fpm -p 9000:9000 -v /var/www/html:/var/www/html mmhk/php-docker:8-fpm
```
