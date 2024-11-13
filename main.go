package main

import (
	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	// Caddy 核心模塊
	_ "github.com/caddyserver/caddy/v2"

	// 這裡導入您的插件
	//_ "github.com/mmhk/caddy-dnspodcn"
	_ "github.com/corazawaf/coraza-caddy"
)

func main() {
	caddycmd.Main()
}
