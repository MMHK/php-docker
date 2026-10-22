# PHP-Docker 

适用于容器化的PHP执行环境

### Environment

|ENV|remark|default value|
|-|-|-|
|WWW_UID|www-data(容器自带fpm执行账户)账户的UID|1000|
|WWW_GID|www-data(容器自带fpm执行账户)账户的GID|1000|
|OPCACHE_JIT|对应php.ini `opcache.jit`|tracing|
|OPCACHE_JIT_BUFFER|对应php.ini `opcache.jit_buffer_size`|128M|

### 來源與安全修補

本鏡像**從原始碼編譯** PHP 7.4.33（基底 `debian:bullseye-slim`），並套用官方
backport 補丁修補 **CVE-2026-109618 / CVE-2026-109619**（PHP2Shell）：

- 補丁：`patches/php-7.4-CVE-2026-109618-109619.patch`（來源 php-src 分支
  `PHP-7.4-CVE-2026-109618-109619`，commit `712e60f9`），可直接在 repo 內審閱。
- 原始碼 tarball 與補丁均以 SHA256 固定，建置時驗證。
- 映像內含證明檔 `/usr/local/etc/php/cve-2026-109618-109619.patched`。
- `phpinfo()` 頁面上有兩個標識可確認已修補：
  - `Additional .ini files parsed` 會列出
    `/usr/local/etc/php/conf.d/zz-cve-2026-109618-109619.ini`
  - `Environment` 區（及 `$_SERVER` / `$_ENV`）有
    `PHP_CVE_PATCHES=CVE-2026-109618,CVE-2026-109619`

> 版本號仍是 `7.4.33`：那是官方最後一版，`7.4.33` 本身無法區分是否已補丁，
> 因此不用改版本字串來當標識。

> PHP 7.4 已於 2022-11 EOL，官方不再提供 7.4 修復版，因此以源碼 backport 方式修補。
> 設計與驗證細節見 `docs/plans/php-7.4-cve-2026-109618-109619-patch.md`。

### 已安裝擴展

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
|shmop||
|ffi||

PECL 擴充（`memcached` `imagick` `mcrypt` `redis` `timezonedb`）以固定版本 + SHA256 的
tarball 安裝（不走 PECL channel），`install-php-extensions` 亦固定為 2.12.3；
原因與升版方式見 `docs/plans/php-7.4-extension-install.md`。


### RUN

```
docker run -d --name php-fpm -p 9000:9000 -v /var/www/html:/var/www/html mmhk/php-docker:7.4-fpm
```
