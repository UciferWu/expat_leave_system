#!/usr/bin/env bash
# =====================================================================
# 员工休假系统 — 绑定域名并启用 HTTPS（同时安装服务器统一入口网关）
# Activer HTTPS sur un nom de domaine (installe aussi la passerelle commune)
#
# 用法 / Usage（root）：
#   bash /opt/leave/app/deploy/aliyun/enable-https.sh leave.公司域名 [证书通知邮箱]
#
# 前提：域名 A 记录已指向本机公网 IP；安全组已放行 80 和 443。
# 可重复运行；更换域名时用新域名再运行一次即可。
# =====================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

DOMAIN="$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | sed -e 's#^https\?://##' -e 's#/.*$##')"
EMAIL="${2:-}"
[ -n "$DOMAIN" ] || die "请提供域名，例如：bash $0 leave.example.com"
printf '%s' "$DOMAIN" | grep -Eq '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' || die "域名格式不正确：$DOMAIN"
[ -f "$SB_DIR/.env" ] || die "尚未安装休假系统，请先运行 install.sh"

GW_DIR="${GW_DIR:-/opt/gateway}"
APP_PORT="${APP_PORT:-8081}"

# ---------------------------------------------------------------------
log "1/5 检查域名解析 / Vérification DNS"
ip="$(curl -fsS -m 3 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null || true)"
[ -n "$ip" ] || ip="$(curl -fsS -m 3 http://100.100.100.200/latest/meta-data/public-ipv4 2>/dev/null || true)"
[ -n "$ip" ] || ip="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || true)"
resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
[ -n "$resolved" ] || die "域名 $DOMAIN 还没有解析（请在域名解析中添加 A 记录指向 ${ip:-本机公网 IP}，生效可能需要几分钟）"
if [ -n "$ip" ] && [ "$resolved" != "$ip" ]; then
  die "域名 $DOMAIN 解析到 $resolved，但本机公网 IP 是 $ip。请修正 A 记录后重试。"
fi
ok "$DOMAIN → $resolved"

# ---------------------------------------------------------------------
log "2/5 休假系统改为本机端口 $APP_PORT，并使用新网址 / Nouvelle adresse"
env_set LEAVE_HTTP_PORT     "127.0.0.1:$APP_PORT"
env_set SUPABASE_PUBLIC_URL "https://$DOMAIN"
env_set API_EXTERNAL_URL    "https://$DOMAIN/auth/v1"
env_set SITE_URL            "https://$DOMAIN"
env_set APP_URL             "https://$DOMAIN/"
sync_app
compose up -d --remove-orphans
wait_healthy "supabase-auth supabase-storage supabase-edge-functions supabase-studio supabase-envoy leave-web" 300
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$APP_PORT/")"
[ "$code" = 200 ] || die "休假系统在本机 $APP_PORT 端口无响应（HTTP $code）"
ok "休假系统：127.0.0.1:$APP_PORT"

# ---------------------------------------------------------------------
log "3/5 安装统一入口网关 / Passerelle"
mkdir -p "$GW_DIR/sites"
cp -f "$DEPLOY_DIR/../gateway/docker-compose.yml" "$GW_DIR/docker-compose.yml"
cp -f "$DEPLOY_DIR/../gateway/README.md" "$GW_DIR/README.md"
{
  echo "# 由 enable-https.sh 生成。各应用的配置在 sites/ 目录中。"
  if [ -n "$EMAIL" ]; then printf '{\n\temail %s\n}\n\n' "$EMAIL"; fi
  echo "import /etc/caddy/sites/*.caddy"
} > "$GW_DIR/Caddyfile"
cat > "$GW_DIR/sites/leave.caddy" <<EOF
# 员工休假系统
$DOMAIN {
	encode gzip
	reverse_proxy 127.0.0.1:$APP_PORT
}
EOF
# 直接用 IP 访问时跳转到休假系统（以后可改为其他默认页面）
cat > "$GW_DIR/sites/00-default.caddy" <<EOF
# 用 IP 或未配置的域名访问时的默认处理
http:// {
	redir https://$DOMAIN{uri} 302
}
EOF

if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --permanent --add-service=http --add-service=https >/dev/null && firewall-cmd --reload >/dev/null && ok "firewalld 已放行 80/443"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null && ok "ufw 已放行 80/443"
fi

(cd "$GW_DIR" && docker compose pull -q && docker compose up -d)
sleep 3
docker exec gateway-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
ok "网关已启动：$GW_DIR"

# ---------------------------------------------------------------------
log "4/5 申请 HTTPS 证书（通常 10–60 秒）/ Certificat"
cert_ok=""
for _ in $(seq 1 36); do
  # 证书文件已生成，且通过 https 能访问到休假系统
  if docker exec gateway-caddy sh -c "ls /data/caddy/certificates/*/$DOMAIN/$DOMAIN.crt" >/dev/null 2>&1 \
     && [ "$(curl -sk -o /dev/null -m 10 -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/")" = 200 ]; then
    cert_ok=1; break
  fi
  sleep 5
done
if [ -z "$cert_ok" ]; then
  docker logs --tail 25 gateway-caddy 2>&1 | sed 's/^/      /' >&2
  die "证书申请未成功。请确认：① 安全组已放行 80 和 443；② 域名 A 记录指向 $ip。修正后重新运行本脚本即可。"
fi
ok "证书已生效"

# ---------------------------------------------------------------------
log "5/5 完成 / Terminé"
cat <<EOF

  新网址 / Nouvelle adresse : $(printf '\033[1;32m')https://$DOMAIN$(printf '\033[0m')
  直接用 IP 访问会自动跳转到新网址。

  ⚠ 请确认安全组已放行 TCP 443（入方向），否则员工在外网无法打开 https 网址。
  以后新增其他应用：见 $GW_DIR/README.md
EOF
