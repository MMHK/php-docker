# Caddy 對 HTTP/2 WebSocket（RFC 8441）回 502 問題分析

- **文件日期**：2026-10-23
- **影響範圍**：經 Caddy 反向代理的 WebSocket 站點（實測案例：`motors-chat.dev.mixmedia.com/io/ws`）
- **嚴重度**：高（現代 Chrome 全部無法建立 WebSocket，連線層即失敗）
- **狀態**：已定位根因，待修復與驗證

---

## 1. 現象

前端（Chrome 156）開啟頁面後，WebSocket 無法連線，Console 顯示：

```
WebSocket connection to 'wss://motors-chat.dev.mixmedia.com/io/ws?token=...' failed
Connection Error: [object Event]
```

- DevTools → Network → `WS` 篩選：多條 `io/ws?token=...` 全部失敗
- **Messages 分頁為空**、`Length = N/A` → 完全沒有收到任何 frame（連 30 秒心跳都沒有）
- 同一條 URL、同一個 token，用 **Node.js `ws`** 客戶端卻能正常連線並收到 heartbeat

也就是說：**不是後端 WebSocket（Ratchet）的問題，也不是 token / auth 的問題，而是 handshake 在 Caddy 這一層就失敗了。**

---

## 2. 關鍵證據

### 2.1 Caddy access log

```json
{
  "msg": "handled request",
  "request": {
    "remote_ip": "192.168.33.106",
    "proto": "HTTP/2.0",
    "method": "CONNECT",
    "host": "motors-chat.dev.mixmedia.com",
    "uri": "/io/ws?token=dfda31350947bd4cc45c281f2deb13e5",
    "headers": {
      "Origin": ["https://motors-chat.dev.mixmedia.com"],
      "Sec-Websocket-Extensions": ["permessage-deflate; client_max_window_bits"],
      "Sec-Websocket-Version": ["13"],
      ":protocol": ["websocket"]
    },
    "tls": { "version": 772, "proto": "h2", "server_name": "motors-chat.dev.mixmedia.com" }
  },
  "status": 502,
  "resp_headers": {
    "Server": ["Caddy"],
    "Service-By": ["demo3-https"],
    "Content-Type": ["text/html; charset=utf-8"]
  }
}
```

三個關鍵欄位：

| 欄位 | 意義 |
|---|---|
| `"proto": "HTTP/2.0"` + `"method": "CONNECT"` + `":protocol": ["websocket"]` | 瀏覽器使用 **RFC 8441「WebSocket over HTTP/2」的 Extended CONNECT**，而不是傳統 `GET` + `Upgrade: websocket` |
| `"status": 502` | Caddy 接受請求但無法正常轉發到後端，自行回 502 |
| `"Server": ["Caddy"]` | 502 是 Caddy 產生的，不是後端 nginx / Ratchet 回的 |

### 2.2 對照測試（同一台機器、同一個 token）

| 測試方式 | 走訪協定 | 結果 |
|---|---|---|
| Node.js `ws`（一般 / 帶 Origin / 帶 Cookie / 帶 `permessage-deflate` / 完整 Chrome header） | HTTP/1.1 Upgrade | **101 + heartbeat** ✅ |
| Node.js `ws` + 無效 token / 無 token | HTTP/1.1 Upgrade | `{"event":"error.auth"}` 後 close（正常行為） |
| Chrome 156 | HTTP/2 Extended CONNECT | **502** ❌ |

> 結論：後端 WebSocket 服務與 token 驗證完全正常，差別只在「客戶端用哪種協定發起 handshake」。

---

## 3. 根因分析

### 3.1 為什麼 Chrome 會用 HTTP/2 開 WebSocket

RFC 8441 定義了在 HTTP/2 連線上用 **Extended CONNECT**（`method=CONNECT` + `:protocol=websocket`）建立 WebSocket。
只有在伺服器於 HTTP/2 SETTINGS 中送出 `SETTINGS_ENABLE_CONNECT_PROTOCOL = 1` 時，客戶端才「可以」使用它。

**關鍵變化：Go 1.24 起，`net/http` 的 HTTP/2 server 預設送出 `SETTINGS_ENABLE_CONNECT_PROTOCOL`。**
Chrome 看到這個 capability 後，對同源（same-origin）的 `wss://` 就會改用 Extended CONNECT。

可用的關閉開關：

```bash
GODEBUG=http2xconnect=0
```

（Go 1.24 之前預設關閉；Go 1.24 之後預設開啟，`http2xconnect=0` 可還原舊行為。
若使用的是 `golang.org/x/net/http2`（Caddy 部分版本），該套件仍預設關閉，需 `http2xconnect=1` 才會開啟。
無論哪種情況，本次事故的 Caddy access log 已出現 `:protocol: websocket`，代表**實際部署的 gateway 確實有宣告支援**。）

### 3.2 Caddy 端發生什麼

- Caddy 基於 Go。若編譯 Caddy 所用的 Go 版本 ≥ 1.24，就會自動宣告支援 Extended CONNECT。
- 後端（nginx → Ratchet）只支援傳統 HTTP/1.1 `Upgrade: websocket`，不支援 RFC 8441。
- Caddy 2.11.x 的 `reverse_proxy` 會嘗試把 h2/h3 Extended CONNECT **改寫成 HTTP/1.1 Upgrade** 再送給後端（原始碼註解有說明），但實測這台 gateway 回 `502`，表示：
  - 部署的 Caddy 版本較舊（尚無此改寫邏輯），或
  - 改寫後仍與後端（nginx / Ratchet）不相容。

### 3.3 影響放大：HTTP/3

回應標頭有 `Alt-Svc: h3=":443"; ma=2592000`。
在 Go 的 HTTP/3 實作中，Extended CONNECT **預設就是開啟的**，因此即使只關掉 h2 那一邊，Chrome 仍可能改用 h3 發起 WebSocket，一樣會失敗。

### 3.4 為什麼 Node 測試會過、瀏覽器不會

`ws`（Node）只走 HTTP/1.1 `GET ... Upgrade: websocket`，不會自動升級到 HTTP/2/3 Extended CONNECT，因此完全繞過有問題的路徑。這也說明**用 Node / curl 測通不代表瀏覽器可用**。

### 3.5 實際部署拓撲與設定（public vhost 通用 proxy）

實際的 public vhost 是一個 frps 後方的通用反向代理，設定大致如下（節錄）：

```text
Chrome ──wss──▶ frps ──▶ Caddy (*.dev.mixmedia.com, TLS/ACME)
                              │
                              ├─ @websockets (h1 Upgrade)  ──▶ 192.168.33.8:8800
                              └─ 一般 reverse_proxy         ──▶ 192.168.33.8:8800
                                                              └─▶ nginx ─▶ Ratchet (ws:5343)
```

```caddyfile
*.dev.mixmedia.com {
    @websockets {
        header Connection *Upgrade*
        header Upgrade    websocket
    }
    reverse_proxy @websockets 192.168.33.8:8800

    reverse_proxy {
        to 192.168.33.8:8800
        transport http {
            dial_timeout 12s
            response_header_timeout 120s
        }
    }
    ...
}
```

問題出在 **`@websockets` matcher 只認得 HTTP/1.1 的 Upgrade 形式**：

| 客戶端行為 | 會帶的標頭 | `@websockets` 是否命中 |
|---|---|---|
| HTTP/1.1 `GET` | `Connection: Upgrade` + `Upgrade: websocket` | ✅ 命中，走專用 `reverse_proxy` |
| HTTP/2 Extended CONNECT | `method=CONNECT` + `:protocol=websocket`，**沒有** `Connection` / `Upgrade` | ❌ 不命中 |

所以 Chrome 的 Extended CONNECT 會掉到第二個（預設）`reverse_proxy`，被原樣轉給上游 `192.168.33.8:8800`；上游不支援 RFC 8441，最終就是 Caddy log 看到的 `status=502`。

這也解釋了為什麼 Node（HTTP/1.1）會命中 `@websockets` 而正常，Chrome 卻一定失敗——**問題與 token、後端 Ratchet 完全無關**。

> 補充：Caddy 的 `reverse_proxy` 本身就會轉發 HTTP/1.1 Upgrade，`@websockets` 這個分流其實是冗餘的；留著無害，但它不能解決 RFC 8441。

---

## 4. 解決方案

### 方案 A（最小改動、可立即驗證）：關閉 Go 的 Extended CONNECT 宣告

在 Caddy 服務的環境變數加入：

```yaml
# docker-compose.yml
  caddy:
    environment:
      - TZ=Asia/Hong_Kong
      - GODEBUG=http2xconnect=0
```

```dockerfile
# 或 Dockerfile
ENV GODEBUG=http2xconnect=0
```

效果：Go 不再送出 `SETTINGS_ENABLE_CONNECT_PROTOCOL`，Chrome 自動退回 HTTP/1.1 `Upgrade`，也就是目前可正常工作的路徑。

**要改的是「public vhost 那台 frps 前面的 Caddy」**（不是後端 `192.168.33.8:8800`）：

```yaml
# 該 Caddy 的 docker-compose / systemd
services:
  caddy:
    environment:
      - GODEBUG=http2xconnect=0
```

或 systemd：

```ini
[Service]
Environment=GODEBUG=http2xconnect=0
```

改完重啟 Caddy 後，`*.dev.mixmedia.com` 的 WebSocket 會自動回到 HTTP/1.1 Upgrade，`@websockets` matcher 也就會命中。

**同時要處理 HTTP/3**，否則 Chrome 仍可能走 h3 Extended CONNECT。擇一：

```caddyfile
# 在既有的 global options block 內加入（注意：servers 選項是「整個 listener」層級，無法只套單一 site）
{
	servers {
		protocols h1 h2
	}
}
```

或在 edge／外層 TLS 終結器上不要對 WebSocket 站點宣告 `Alt-Svc: h3`。

> 注意：目前的 public vhost 是把 TLS 直接做在 Caddy（`tls { issuer acme ... }`），因此 `Alt-Svc: h3` 就是這台 Caddy 發的；`protocols h1 h2` 會關掉整台 Caddy 的 h3，對 dev 域的影響通常可接受。

### 方案 B（正規修法）：升級 Caddy 到 2.11.x

Caddy 2.11 的 `reverse_proxy` 已能把 h2/h3 Extended CONNECT 轉成對後端的 HTTP/1.1 Upgrade（原始碼註解明確提到：假設 backend 不支援時會改寫成 http1.1 upgrade）。

要升級的是 **public vhost 那台 Caddy**。`php-docker` repo 內的 `Dockerfile` 仍使用 `caddy:2.6.2-builder-alpine`，與實際 public vhost 的版本可能不同，請先確認（見第 6 節）：

```dockerfile
FROM caddy:2.11-builder-alpine AS builder
...
FROM caddy:2.11-alpine
```

升級後請以「真實 Chrome」驗證（Node 測試不足以覆蓋此情境）。

### 方案 C（隔離手段）：整個 listener 強制 h1

```caddyfile
{
	servers {
		protocols h1
	}
}
```

- 優點：最暴力、一定回到 HTTP/1.1 Upgrade 路徑，問題立即消失。
- 缺點：**影響這台 Caddy 上的所有 site**（`*.dev.mixmedia.com` 全部失去 h2/h3），且無法只針對單一 vhost。建議只作為臨時止血。

### 方案 D（客戶端臨時繞路，僅供診斷）

- 換 Firefox / 舊版 Chrome 測試
- 或直接用 Node 腳本驗證後端是否正常（本文件附錄 A）

> 不建議要求使用者修改瀏覽器 flags 作為長期方案。

---

## 5. 驗證方式

### 5.1 確認 gateway 是否還會宣告 Extended CONNECT

用支援 h2 的工具觀察 handshake，或直接看 Caddy access log 的 `"proto"` / `"method"`：

- 修復前：`proto=HTTP/2.0`, `method=CONNECT`, 有 `:protocol: websocket`, `status=502`
- 修復後：`proto=HTTP/1.1`, `method=GET`, 有 `Upgrade: websocket`, `status=101`

### 5.2 瀏覽器端

DevTools Console：

```js
const ws = new WebSocket('wss://<host>/io/ws?token=<valid-token>');
ws.onopen = () => console.log('OPEN');
ws.onerror = e => console.log('ERR', e);
ws.onmessage = e => console.log('MSG', e.data);
ws.onclose = e => console.log('CLOSE', e.code, e.reason);
setTimeout(() => console.log('readyState', ws.readyState), 8000); // 0 卡住 / 1 正常
```

預期：`OPEN`，並在 30 秒內收到 `{"event":"heartbeat",...}`。

Network → 該筆 WS 請求：

- Status `101 Switching Protocols`
- Messages 分頁能看到 heartbeat frame

### 5.3 後端（排除法）

Node 腳本（附錄 A）若能拿到 `101` + heartbeat，代表後端 nginx → Ratchet 正常，問題只在 gateway 的協定路徑。

---

## 6. 待辦（Checklist）

- [ ] 確認 public vhost（frps 前方的 Caddy）實際運行的 Caddy 版本與編譯用 Go 版本
      （`caddy version` / `caddy build-info`；確認是否 ≥ Go 1.24 而自動宣告 Extended CONNECT）
- [ ] 在該 Caddy 的服務設定加入 `GODEBUG=http2xconnect=0` 並重啟，用真實 Chrome 驗證
- [ ] 視情況關閉 h3（global `servers { protocols h1 h2 }`），避免 Chrome 改走 h3 Extended CONNECT
- [ ] 若仍失敗，確認上游 `192.168.33.8:8800` 是否為另一層 Caddy/nginx（可能同樣需要處理）
- [ ] 排程升級 Caddy 至 2.11.x（同步更新 `php-docker` 的 `Dockerfile` / `docker-compose.yml` image tag）
- [ ] 更新 Caddyfile 後回歸測試：頁面載入、API、WebSocket（心跳、收發訊息）、WAF（Coraza）皆正常
- [ ] 前端（web-client-v2）修正 `WSService.js` 的 `close(true)` 反向參數問題，避免失敗時無限重連佔滿連線

---

## 7. 相關前端 Bug（同一現象的放大器）

`web-client-v2/src/Services/WSService.js`：

```js
if (msg.event === Event.Error.Auth) {
    console.error("ws error:auth");
    EventBus.dispatchAuthError();
    this.client.close(true);   // BUG
}
```

`ReconnectingWebSocket.close(reconnectEnabled = false)` 的參數語意是「是否開啟自動重連」。
傳 `true` 等於**開啟**自動重連，auth 失敗後會用同一個失效 token 無限重連，把 Chrome 對同一 host 的連線槽位（上限 6 條）佔滿，讓後續連線全部卡在 pending。

建議：

```js
this.client.close(false);       // 停止重連
// 並清除 mm-chat.token，引導重新登入
```

---

## 8. 結論

| 項目 | 結論 |
|---|---|
| WebSocket 後端（nginx / Ratchet） | 正常，HTTP/1.1 Upgrade 可取得 101 |
| PHP auth（`ChatHandler` / `TokenService` / Redis） | 正常，有效 token 可驗證通過 |
| 前端 token 傳遞 | 正常（URL `?token=`） |
| **故障點** | **public vhost 的 Caddy 收到 RFC 8441 Extended CONNECT，因 `@websockets` matcher 不匹配而落入一般 `reverse_proxy`，上游不支援 → 502** |
| 觸發條件 | 瀏覽器（Chrome 156）+ gateway 宣告支援 Extended CONNECT（Go ≥ 1.24）|
| 修復方向 | 關閉 Extended CONNECT 宣告（`GODEBUG=http2xconnect=0`、處理 h3），或升級 Caddy 2.11+ |

---

## 附錄 A：後端快速驗證腳本（Node.js）

```js
const WebSocket = require('ws'); // 或專案內既有 ws 套件路徑

const url = 'wss://<host>/io/ws?token=<valid-token>';
const ws = new WebSocket(url, {
  headers: {
    Origin: 'https://<host>',
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
    'Accept-Encoding': 'gzip, deflate, br, zstd',
    'Sec-Fetch-Mode': 'websocket',
    'Sec-Fetch-Site': 'same-origin',
  },
  perMessageDeflate: true,
});

ws.on('upgrade', r => console.log('upgrade', r.statusCode));
ws.on('message', m => console.log('MSG', m.toString()));
ws.on('error', e => console.log('ERR', e.message));
ws.on('close', (c, r) => console.log('CLOSE', c, r.toString()));

setTimeout(() => process.exit(0), 35000);
```

預期輸出：

```
upgrade 101
MSG {"event":"heartbeat","data":{"time":...,"interval":30}}
```

## 附錄 B：術語

- **RFC 6455**：傳統 WebSocket，透過 HTTP/1.1 `Upgrade: websocket` 建立。
- **RFC 8441**：WebSocket over HTTP/2，使用 `CONNECT` + `:protocol=websocket`（Extended CONNECT）。
- **SETTINGS_ENABLE_CONNECT_PROTOCOL**：HTTP/2 伺服器宣告支援 Extended CONNECT 的 SETTINGS 參數。
- **GODEBUG=http2xconnect=0**：Go 1.24+ 用來關閉 Extended CONNECT 宣告的相容性開關。

## 附錄 C：參考資料

- RFC 8441: https://www.rfc-editor.org/rfc/rfc8441
- Go issue #71128（extended connect 預設開啟 / `http2xconnect`）: https://github.com/golang/go/issues/71128
- Caddy `reverse_proxy` 對 h2/h3 WebSocket 的處理: https://github.com/caddyserver/caddy/blob/master/modules/caddyhttp/reverseproxy/reverseproxy.go
- Caddy issue #5565（WebSocket over HTTP/2 支援）: https://github.com/caddyserver/caddy/issues/5565
- Caddy issue #7309（h2/h3 造成 WebSocket 失效與 `GODEBUG=http2xconnect=1`）: https://github.com/caddyserver/caddy/issues/7309



