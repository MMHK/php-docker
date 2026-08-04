# PHP-Docker 

适用于容器化的PHP执行环境

### Environment

|ENV|remark|default value|
|-|-|-|
|WWW_UID|www-data(容器自带fpm执行账户)账户的UID|1000|
|WWW_GID|www-data(容器自带fpm执行账户)账户的GID|1000|

### 已安装扩展

||||
|-|-|-|
|composer|gd|memcached|
|gettext|imagick|mcrypt|
|mysqli|redis|pdo_mysql|
|pdo_pgsql|pgsql|gmp|
|zstd|opcache|exif|
|bcmath|soap|sockets|
|timezonedb|zip|snmp|
|bz2|shmop|ffi|

### OPcache / JIT

通过独立的 `opcache.ini` 配置，已启用 JIT tracing 模式：

| 设置 | 值 |
|-|-|
|opcache.enable|1|
|opcache.jit|tracing|
|opcache.jit_buffer_size|128M|

如需调整，修改 `opcache.ini` 后重新构建镜像即可。

### RUN

```
docker run -d --name php-fpm -p 9000:9000 -v /var/www/html:/var/www/html mmhk/php-docker:8.3-fpm
```

### 自訂配置（docker-compose）

如果需要覆蓋預設配置，可以透過 volume 掛載自訂文件：

```yaml
version: '3.8'
services:
  php-docker:
    image: mmhk/php-docker:8.3-fpm
    volumes:
      - ./www:/var/www/html
      # 覆蓋 opcache 配置
      - ./config/opcache.ini:/usr/local/etc/php/conf.d/opcache.ini:ro
      # 覆蓋 upload 限制
      - ./config/file-upload.conf:/usr/local/etc/php-fpm.d/file-upload.conf:ro
      # 新增自訂 FPM pool 配置
      - ./config/custom-pool.conf:/usr/local/etc/php-fpm.d/custom-pool.conf:ro
    ports:
      - "9000:9000"
```

**opcache.ini 範例**（調整 JIT buffer）：

```ini
[opcache]
opcache.enable=1
opcache.jit=tracing
opcache.jit_buffer_size=256M
opcache.memory_consumption=256
```

**file-upload.conf 範例**（調整上傳限制）：

```ini
[www]
php_admin_value[post_max_size]=100M
php_admin_value[upload_max_filesize]=95M
```

**custom-pool.conf 範例**（新增 FPM pool）：

```ini
[custom]
user = www-data
group = www-data
listen = 9001
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 5
```

修改配置後重新啟動容器即可生效：

```bash
docker compose down
docker compose up -d
```
