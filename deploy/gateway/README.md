# 服务器统一入口（网关）

服务器上所有网站都通过这个入口对外提供服务：

```
leave.公司域名 ─┐                        ┌─▶ 127.0.0.1:8081  员工休假系统
hr.公司域名    ─┼─▶ 8.218.97.159:80/443 ─┼─▶ 127.0.0.1:8082  （以后的应用）
...            ─┘     gateway-caddy      └─▶ ...
```

- 自动为每个域名申请、续期免费的 HTTPS 证书（Let's Encrypt），http 自动跳转到 https。
- 安装位置：`/opt/gateway`；每个应用一个配置文件：`/opt/gateway/sites/应用名.caddy`。
- 安全组只需开放 **80、443** 两个端口。

## 新增一个应用

1. 让新应用只监听本机的一个空闲端口，例如 `127.0.0.1:8082`（不要占用 80/443）。
2. 在域名解析中添加 A 记录：`hr` → `8.218.97.159`。
3. 在服务器上运行（把域名和端口换成实际的）：

```bash
cat > /opt/gateway/sites/hr.caddy <<'EOF'
hr.公司域名 {
	encode gzip
	reverse_proxy 127.0.0.1:8082
}
EOF
docker exec gateway-caddy caddy reload --config /etc/caddy/Caddyfile
```

几十秒后即可通过 `https://hr.公司域名` 访问。

## 常用命令

| 操作 | 命令 |
|---|---|
| 查看网关日志（证书申请情况） | `docker logs --tail 50 gateway-caddy` |
| 修改配置后重新加载 | `docker exec gateway-caddy caddy reload --config /etc/caddy/Caddyfile` |
| 重启网关 | `cd /opt/gateway && docker compose restart` |
