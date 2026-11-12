# PHP-Docker

适用于容器化的 PHP 7.4 FPM 执行环境（`mmhk/php-docker:7.4-fpm`）。

镜像是多阶段构建：`builder` 从 PHP 7.4.33 源码编译并内嵌扩展，`runtime` 只保留
运行期文件，不包含源码、编译器与构建依赖。

### Environment

| ENV | remark | default value |
|-|-|-|
| WWW_UID | www-data（容器自带 fpm 执行账户）的 UID | 1000 |
| WWW_GID | www-data（容器自带 fpm 执行账户）的 GID | 1000 |
| OPCACHE_JIT | 对应 php.ini `opcache.jit` | tracing |
| OPCACHE_JIT_BUFFER | 对应 php.ini `opcache.jit_buffer_size` | 128M |

### Build

```bash
# final runtime image（不含源码与 toolchain）
docker build -t mmhk/php-docker:7.4-fpm .

# builder stage（保留 PHP source、toolchain，供静态扩展安装）
docker build --target builder -t mmhk/php-docker:7.4-fpm-builder .
```

多架构发布：

```bash
docker buildx build --platform linux/amd64,linux/arm64 \
  -t mmhk/php-docker:7.4-fpm --push .
```

### 已安装扩展

| 扩展 | 安装方式 |
|-|-|
| bcmath bz2 exif ffi gd gettext mysqli pdo_mysql soap sockets zip snmp shmop | 静态内嵌 |
| memcached imagick mcrypt redis timezonedb | 静态内嵌（PECL 固定版本 + SHA256） |
| opcache | shared（PHP 7.4 强制 shared） |
| sodium | shared |
| composer | 固定版本 `2.11.2` |

扩展清单与 configure flags 在 `scripts/static-extensions.conf`；PECL 版本与
SHA256 在 `scripts/build-php-static.sh`。除 `opcache` / `sodium` 外，
运行期没有对应的 `.so` 与 `extension=` ini。

### 额外静态扩展

只能在 **builder stage** 使用，因为静态内嵌需要重新 link `php` / `php-fpm`：

```bash
docker run --rm mmhk/php-docker:7.4-fpm-builder \
  docker-php-ext-static-install redis

docker run --rm mmhk/php-docker:7.4-fpm-builder \
  docker-php-ext-static-remove redis
```

PECL 扩展需先把源码放进 builder 的 `/usr/src/php/ext/<name>`；脚本不会自动
解析 apt/PECL 依赖。final image 已移除 source 与 toolchain，不能直接使用。

### 安全修补与 CA

- 从 PHP 7.4.33 源码构建，套用官方 backport 补丁
  `patches/php-7.4-CVE-2026-109618-109619.patch`
  （CVE-2026-109618 / CVE-2026-109619，PHP2Shell）。
- 原始码 tarball、补丁、PECL tarball 均以 SHA256 固定。
- 镜像内含证明文件 `/usr/local/etc/php/cve-2026-109618-109619.patched`；
  `phpinfo()` 会列出 `zz-cve-2026-109618-109619.ini`，并显示
  `PHP_CVE_PATCHES`。
- PHP 的 trust store 使用 `/usr/local/share/ca-certificates/cacert.pem`，
  由 `ca-bundle.ini` 绑定 `openssl.cafile` 与 `curl.cainfo`；系统
  `/etc/ssl/certs` 不变。

### RUN

```bash
docker run -d --name php-fpm -p 9000:9000 \
  -v /var/www/html:/var/www/html \
  mmhk/php-docker:7.4-fpm
```

### 文档与脚本

| 路径 | 用途 |
|-|-|
| `docs/plans/2026-11-12-php-7.4-static-extensions.md` | 当前静态内嵌架构与验证记录 |
| `docs/plans/php-7.4-cve-2026-109618-109619-patch.md` | CVE patch 设计与来源 |
| `scripts/build-php-static.sh` | builder 内完整 PHP 构建流程 |
| `scripts/static-extensions.conf` | 扩展 → configure flags 对照表 |
| `docker-php-scripts/docker-php-ext-static-install` | builder 内新增静态扩展 |
| `docker-php-scripts/docker-php-clean` | 清理 source / build deps（builder 用） |
| `docker-php-scripts/docker-php-source` | 管理 `/usr/src/php` 源码目录 |

> `docs/plans/php-7.4-extension-install.md` 是旧的 IPE 方案，已被静态内嵌取代。
