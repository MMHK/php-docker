Caddy with WAF and OWASP 

### 项目概述
此项目旨在构建一个集成了 WAF (Web Application Firewall) 和 OWASP 防护规则的 Caddy 服务器，以增强 Web 应用的安全性。通过使用 Coraza 插件，Caddy 可以有效地检测和阻止恶意请求，保护应用程序免受常见的 Web 攻击。

### 关键组件

- **Caddy**: 一个现代化的、高性能的 Web 服务器，支持 HTTP/2 和 HTTP/3。
- **Coraza**: 一个开源的 WAF 引擎，基于 ModSecurity 规则集，可以作为 Caddy 的插件使用。
- **OWASP 核心规则集 (CRS)**: 一组预定义的安全规则，用于检测和阻止常见的 Web 攻击，如 SQL 注入、XSS 等。

### 功能特点

- **实时防护**：Coraza 实时分析和过滤 HTTP 请求，防止恶意攻击。
- **灵活配置**：可以通过 Caddyfile 进行详细的配置，包括规则集的选择和自定义规则的添加。
- **高性能**：Caddy 和 Coraza 的结合提供了高性能的 WAF 解决方案，适用于高流量网站。
- **易于维护**：Caddy 和 Coraza 的更新和维护相对简单，可以通过官方渠道获取最新的安全更新。

### 使用场景

- **企业级应用**：适用于需要高安全性保障的企业级 Web 应用。
- **中小型企业**：为中小企业提供经济高效的 WAF 解决方案。
- **个人开发者**：帮助个人开发者快速搭建安全的 Web 服务器。


## 如何启用 WAF 防护功能

1. 编辑 `coraza/coraza.conf-recommended` 文件：

其中 
```shell
# 启动 WAF 防护
SecRuleEngine On 
```

2. 保存并重启 Caddy 服务以应用更改。

## 如何测试 WAF 效果

### 使用 gotestwaf

- [gotestwaf](https://github.com/wallarm/gotestwaf) 是一个用于测试 WAF 防护效果的工具。
- 运行以下命令进行测试：
```shell
docker run --rm -it \
  -v ${PWD}/reports:/app/reports \
  wallarm/gotestwaf \
  --url=<your_url> \
  --noEmailReport
```

### 使用 blazehttp

- [blazehttp](https://github.com/chaitin/blazehttp) 是另一个用于测试 WAF 防护效果的工具。
- 运行以下命令进行测试：

```shell
docker run --rm -it \
  --net=host \
  chaitin/blazehttp:latest \
  chaitin/blazehttp:latest -t <your_url>
```


## 注意事项

- 在生产环境中，请确保 WAF 配置正确无误，避免误拦截合法请求。
- 定期更新 WAF 规则以应对新的安全威胁。


希望这个项目能帮助你更好地保护你的 Web 应用！