#!/usr/bin/env bash
# =====================================================================
# 人力报告平台 — 在已部署员工休假系统的服务器上安装第二套独立的 Supabase
#
# 用法（root）：
#   cd /opt/leave/app && git pull
#   bash /opt/leave/app/deploy/hr/install.sh hr.公司域名
#
# 前提：
#   - 员工休假系统已安装并已启用 HTTPS（Docker 与网关 /opt/gateway 已就绪）
#   - 域名 A 记录 hr.公司域名 → 本机公网 IP
#
# 安装完成后是一个空的平台；数据用 migrate.sh 从 Supabase 云迁移过来。
# 可重复运行：已生成的密钥会保留。
# =====================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/hrlib.sh"
require_root

DOMAIN="$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | sed -e 's#^https\?://##' -e 's#/.*$##')"
if [ -z "$DOMAIN" ] && [ -f "$SB_DIR/.env" ]; then DOMAIN="$(env_get SITE_URL | sed -e 's#^https\?://##' -e 's#/.*$##')"; fi
[ -n "$DOMAIN" ] || die "请提供域名，例如：bash $0 hr.example.com"
printf '%s' "$DOMAIN" | grep -Eq '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' || die "域名格式不正确：$DOMAIN"

# ---------------------------------------------------------------------
log "1/7 检查环境"
command -v docker >/dev/null && docker compose version >/dev/null 2>&1 || die "没有 Docker，请先完成员工休假系统的安装"
command -v jq >/dev/null || export PATH="/usr/local/bin:$PATH"
command -v jq >/dev/null || die "没有 jq"
[ -f "$GW_DIR/Caddyfile" ] && docker ps --format '{{.Names}}' | grep -qx gateway-caddy \
  || die "没有找到网关（gateway-caddy）。请先为员工休假系统运行 enable-https.sh"
mem_free=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
ok "可用内存 ${mem_free} MB，磁盘可用 ${disk_gb} GB"
[ "$mem_free" -ge 1500 ] || die "可用内存不足 1.5 GB"
[ "$disk_gb" -ge 8 ] || die "磁盘可用空间不足 8 GB"
for p in "$HR_WEB_PORT" "$HR_API_PORT"; do
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$p\$" && ! docker ps --format '{{.Names}}' | grep -q '^hr-'; then
    die "本机端口 $p 已被占用"
  fi
done

ip="$(curl -fsS -m 3 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null || true)"
[ -n "$ip" ] || ip="$(curl -fsS -m 3 http://100.100.100.200/latest/meta-data/public-ipv4 2>/dev/null || true)"
resolved="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}')"
[ -n "$resolved" ] || die "域名 $DOMAIN 还没有解析。请添加 A 记录指向 ${ip:-本机公网 IP}，几分钟后重试"
[ -z "$ip" ] || [ "$resolved" = "$ip" ] || die "域名 $DOMAIN 解析到 $resolved，但本机公网 IP 是 $ip"
ok "$DOMAIN → $resolved"

# ---------------------------------------------------------------------
log "2/7 获取人力报告平台代码"
mkdir -p "$HR_BASE" && chmod 700 "$HR_BASE"
if [ -d "$HR_APP/.git" ]; then
  git -C "$HR_APP" pull -q --ff-only || warn "代码更新失败，继续使用现有版本"
else
  git clone -q "$HR_REPO_URL" "$HR_APP" || die "无法下载 $HR_REPO_URL"
fi
ok "$(git -C "$HR_APP" log -1 --format='%h %s')"

# ---------------------------------------------------------------------
log "3/7 生成 Supabase 配置（第二套独立实例）"
if [ -f "$SB_DIR/.env" ]; then
  ok "已存在，保留原有密钥：$SB_DIR/.env"
else
  mkdir -p "$SB_DIR"
  cp -a "$DEPLOY_DIR/supabase-docker/." "$SB_DIR/"
  cp "$SB_DIR/.env.example" "$SB_DIR/.env"
  echo "ref=$SB_REF" > "$SB_DIR/.supabase-version"
  (cd "$SB_DIR" && sh utils/generate-keys.sh --update-env >/dev/null) || die "密钥生成失败"
  (cd "$SB_DIR" && sh utils/add-new-auth-keys.sh --update-env >/dev/null) || die "新版 API 密钥生成失败"
  rm -f "$SB_DIR/.env.old"
  grep -q '^JWT_SECRET=your-super-secret' "$SB_DIR/.env" && die "密钥未正确生成"
  ok "随机密钥已生成（与休假系统不同）"
fi

URL="https://$DOMAIN"
env_set COMPOSE_PROJECT_NAME     "hr"
env_set COMPOSE_FILE             "docker-compose.yml:docker-compose.hr.yml"
env_set SUPABASE_PUBLIC_URL      "$URL"
env_set API_EXTERNAL_URL         "$URL/auth/v1"
env_set SITE_URL                 "$URL"
env_set ADDITIONAL_REDIRECT_URLS "$URL/**"
env_set API_GW_HTTP_PORT         "127.0.0.1:$HR_API_PORT"
env_set HR_HTTP_PORT             "127.0.0.1:$HR_WEB_PORT"
# 与原平台一致：允许用公司邮箱自助注册，注册后需点邮件中的链接验证
env_set DISABLE_SIGNUP           "false"
env_set ENABLE_EMAIL_SIGNUP      "true"
env_set ENABLE_EMAIL_AUTOCONFIRM "false"
env_set ENABLE_PHONE_SIGNUP      "false"
env_set ENABLE_ANONYMOUS_USERS   "false"
env_set STUDIO_DEFAULT_ORGANIZATION "Winning Consortium"
env_set STUDIO_DEFAULT_PROJECT   "HR 工作平台"

# 注册验证 / 重置密码邮件：沿用休假系统已经设置好的腾讯企业邮箱
if [ "$(env_get SMTP_HOST)" = "supabase-mail" ] || [ -z "$(env_get SMTP_HOST)" ]; then
  lh="$(SB_DIR="$LEAVE_SB_DIR" env_get MAIL_SMTP_HOST)"
  if [ -n "$lh" ]; then
    env_set SMTP_HOST "$lh"
    env_set SMTP_PORT "$(SB_DIR="$LEAVE_SB_DIR" env_get MAIL_SMTP_PORT)"
    env_set SMTP_USER "'$(SB_DIR="$LEAVE_SB_DIR" env_get MAIL_SMTP_USER)'"
    env_set SMTP_PASS "'$(SB_DIR="$LEAVE_SB_DIR" env_get MAIL_SMTP_PASS)'"
    env_set SMTP_ADMIN_EMAIL "$(SB_DIR="$LEAVE_SB_DIR" env_get MAIL_SMTP_USER)"
    env_set SMTP_SENDER_NAME "'HR 工作平台'"
    ok "发信邮箱：沿用休假系统的设置（$lh，$(env_get SMTP_ADMIN_EMAIL)）"
  else
    warn "休假系统还没有设置 SMTP 邮箱；注册验证和找回密码邮件将无法发送。设置后重新运行本脚本即可。"
  fi
else
  ok "发信邮箱：$(env_get SMTP_HOST)（$(env_get SMTP_ADMIN_EMAIL)）"
fi
chmod 600 "$SB_DIR/.env"
ok ".env 已配置"

# ---------------------------------------------------------------------
log "4/7 部署网页"
hr_sync_site

# ---------------------------------------------------------------------
log "5/7 启动服务（首次约 3–10 分钟）"
hr_compose pull -q
hr_compose up -d --remove-orphans
wait_healthy "$HR_CONTAINERS" 900
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HR_WEB_PORT/")"
[ "$code" = 200 ] || die "网页在本机 $HR_WEB_PORT 端口无响应（HTTP $code）"
ok "本机 127.0.0.1:$HR_WEB_PORT 正常"

# ---------------------------------------------------------------------
log "6/7 网关：$DOMAIN → 127.0.0.1:$HR_WEB_PORT（自动申请 HTTPS 证书）"
cat > "$GW_DIR/sites/hr.caddy" <<EOF
# 人力报告平台
$DOMAIN {
	encode gzip
	request_body {
		max_size 60MB
	}
	reverse_proxy 127.0.0.1:$HR_WEB_PORT
}
EOF
docker exec gateway-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
  || die "网关配置重新加载失败：docker logs --tail 30 gateway-caddy"
for i in $(seq 1 24); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$URL/" || true)"
  [ "$code" = 200 ] && break
  sleep 5
done
[ "$code" = 200 ] && ok "$URL 可以访问" || warn "暂时无法通过 $URL 访问（HTTP $code），证书可能仍在申请中：docker logs --tail 30 gateway-caddy"

# ---------------------------------------------------------------------
log "7/7 每日自动备份"
chmod +x "$HR_DEPLOY_DIR"/*.sh
cat > /etc/cron.d/hr-backup <<EOF
# 人力报告平台：每天 02:45 备份数据库和附件，保留 14 天
45 2 * * * root bash $HR_DEPLOY_DIR/backup.sh >> $HR_BASE/backup.log 2>&1
EOF
ok "$HR_BASE/backups"

users="$(hr_sql -tA -c "select count(*) from auth.users" 2>/dev/null || echo '?')"
cat <<EOF

$(printf '\033[1;32m')人力报告平台已安装$(printf '\033[0m')

  网址          : $URL
  当前账号数    : $users

  下一步：把 Supabase 云上的数据迁移过来
    1) 先检查（只读，不改动任何数据）：bash $HR_DEPLOY_DIR/migrate.sh check
    2) 演练迁移：                       bash $HR_DEPLOY_DIR/migrate.sh run

  数据库管理后台（Studio）：在自己电脑上运行
    ssh -p 60022 -L 8100:127.0.0.1:$HR_API_PORT <堡垒机账号>@<堡垒机地址>
  然后浏览器打开 http://localhost:8100（用户名 $(env_get DASHBOARD_USERNAME)，密码见 $SB_DIR/.env 的 DASHBOARD_PASSWORD）
EOF
