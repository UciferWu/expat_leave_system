#!/usr/bin/env bash
# =====================================================================
# 员工休假系统 — 阿里云 ECS 一键部署（香港 / 海外地域）
# Déploiement en une commande sur un serveur Linux (Alibaba Cloud ECS)
#
# 用法 / Usage（root）：
#   sudo git clone https://github.com/UciferWu/expat_leave_system /opt/leave/app
#   sudo bash /opt/leave/app/deploy/aliyun/install.sh
#
# 可选环境变量 / Variables facultatives :
#   PUBLIC_URL=http://1.2.3.4      对外地址（默认自动获取公网 IP）
#   ADMIN_EMAIL / ADMIN_NAME / ADMIN_PASSWORD   首个管理员（不填则交互输入）
#
# 可重复运行：已完成的步骤会自动跳过。
# =====================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root

# ---------------------------------------------------------------------
log "1/8 检查系统 / Système"
. /etc/os-release
case "$ID" in
  ubuntu|debian) FAM=debian ;;
  *) case " ${ID} ${ID_LIKE:-} " in
       *" rhel "*|*" centos "*|*" fedora "*|*" anolis "*|*" alinux "*) FAM=rhel ;;
       *) die "暂不支持的系统：$PRETTY_NAME（支持 Alibaba Cloud Linux 3、CentOS/Rocky/Alma 8+、Ubuntu、Debian）" ;;
     esac ;;
esac
PKG="$(command -v dnf || command -v yum || true)"
ok "$PRETTY_NAME"

mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
ok "内存 ${mem_mb} MB，磁盘可用 ${disk_gb} GB"
[ "$mem_mb" -ge 1700 ] || die "内存不足：至少需要 2 GB（建议 4 GB）"
[ "$disk_gb" -ge 10 ] || die "磁盘空间不足：至少需要 10 GB 可用空间"

# ---------------------------------------------------------------------
log "2/8 安装基础软件 / Paquets de base"
if [ "$FAM" = debian ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq git curl openssl jq ca-certificates gnupg cron >/dev/null
  systemctl enable --now cron >/dev/null 2>&1 || true
else
  "$PKG" install -y -q git curl openssl jq ca-certificates cronie >/dev/null
  "$PKG" install -y -q dnf-plugins-core >/dev/null 2>&1 || "$PKG" install -y -q yum-utils >/dev/null 2>&1 || true
  systemctl enable --now crond >/dev/null 2>&1 || true
fi
ok "git / curl / openssl / jq / cron"

# ---------------------------------------------------------------------
log "3/8 安装 Docker / Docker"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "已安装：$(docker --version)"
else
  # 使用阿里云 Docker 镜像源（ECS 内网访问更快）
  if [ "$FAM" = debian ]; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://mirrors.aliyun.com/docker-ce/linux/${ID}/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/${ID} ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
  else
    if [ "$ID" = alinux ]; then
      # Alibaba Cloud Linux 3 需要此插件才能使用 CentOS 8 的 Docker 源
      "$PKG" install -y -q dnf-plugin-releasever-adapter --repo alinux3-plus >/dev/null 2>&1 || true
    fi
    if command -v dnf >/dev/null 2>&1; then
      dnf config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo >/dev/null
    else
      yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo >/dev/null
    fi
    "$PKG" install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
  fi
  systemctl enable --now docker >/dev/null
  ok "$(docker --version)"
fi
docker compose version >/dev/null 2>&1 || die "docker compose 插件不可用"

# 内存小于 4 GB 时增加 2 GB 交换空间，避免内存不足
if [ "$mem_mb" -lt 3500 ] && [ -z "$(swapon --show 2>/dev/null)" ]; then
  log "内存 ${mem_mb} MB，添加 2 GB 交换空间 / Ajout de 2 Go de swap"
  fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "交换空间已启用"
fi

# 主机自带防火墙放行网页端口（阿里云安全组仍需在控制台单独放行）
port="${LEAVE_HTTP_PORT:-80}"
if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null && firewall-cmd --reload >/dev/null && ok "firewalld 已放行 ${port}/tcp"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${port}/tcp" >/dev/null && ok "ufw 已放行 ${port}/tcp"
fi

# ---------------------------------------------------------------------
log "4/8 对外地址 / Adresse publique"
if [ -z "${PUBLIC_URL:-}" ]; then
  ip="$(curl -fsS -m 3 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -fsS -m 3 http://100.100.100.200/latest/meta-data/public-ipv4 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || die "无法获取公网 IP，请这样运行：PUBLIC_URL=http://你的公网IP bash $0"
  PUBLIC_URL="http://$ip"
fi
PUBLIC_URL="${PUBLIC_URL%/}"
ok "$PUBLIC_URL"

# ---------------------------------------------------------------------
log "5/8 生成 Supabase 配置（官方 $SB_REF）/ Configuration Supabase"
mkdir -p "$LEAVE_BASE"
if [ -f "$SB_DIR/.env" ]; then
  ok "已存在，保留原有密钥：$SB_DIR/.env"
else
  curl -fsSL "https://raw.githubusercontent.com/supabase/supabase/refs/tags/${SB_REF}/docker/setup.sh" -o /tmp/supabase-setup.sh \
    || die "无法下载 Supabase 官方安装脚本（请检查主机能否访问 GitHub）"
  # 官方脚本：下载配置文件、生成全部密钥（不再安装软件，也不交互）
  (cd "$LEAVE_BASE" && sh /tmp/supabase-setup.sh --skip-deps -y --ref "$SB_REF" --project-dir supabase)
  [ -f "$SB_DIR/.env" ] || die "Supabase 配置生成失败"
  ok "配置和密钥已生成"
fi

env_set SUPABASE_PUBLIC_URL      "$PUBLIC_URL"
env_set API_EXTERNAL_URL         "$PUBLIC_URL/auth/v1"
env_set SITE_URL                 "$PUBLIC_URL"
env_set DISABLE_SIGNUP           "true"      # 只能由管理员建号
env_set ENABLE_EMAIL_AUTOCONFIRM "true"
env_set ENABLE_PHONE_SIGNUP      "false"
env_set ENABLE_ANONYMOUS_USERS   "false"
env_set FUNCTIONS_VERIFY_JWT     "false"     # 函数内部自行校验登录身份
env_set API_GW_HTTP_PORT         "127.0.0.1:8000"   # 网关只在本机开放，对外统一走 80 端口
env_set COMPOSE_FILE             "docker-compose.yml:docker-compose.leave.yml"
env_set STUDIO_DEFAULT_ORGANIZATION "Winning Consortium"
env_set STUDIO_DEFAULT_PROJECT   "员工休假系统"
env_set APP_URL                  "$PUBLIC_URL/"
env_default LEAVE_HTTP_PORT      "80"
env_default RESEND_API_KEY       ""
env_default MAIL_FROM            ""
chmod 600 "$SB_DIR/.env"
ok ".env 已配置"

# ---------------------------------------------------------------------
log "6/8 部署网页和函数 / Site et fonctions"
sync_app

# ---------------------------------------------------------------------
log "7/8 启动服务（首次需下载镜像，约 5–15 分钟）/ Démarrage"
compose pull -q
compose up -d --remove-orphans
wait_healthy "supabase-db supabase-auth supabase-rest supabase-storage supabase-studio supabase-envoy supabase-edge-functions leave-web" 900
apply_migrations

# ---------------------------------------------------------------------
log "8/8 管理员账号与备份 / Administrateur et sauvegardes"
users="$(db_sql -tA -c "select count(*) from public.profiles")"
if [ "$users" = "0" ]; then
  if [ -z "${ADMIN_EMAIL:-}" ]; then
    echo "    创建第一个管理员账号 / Premier compte administrateur"
    read -rp  "    邮箱 E-mail : " ADMIN_EMAIL < /dev/tty
    read -rp  "    姓名 Nom : " ADMIN_NAME < /dev/tty
    while :; do
      read -rsp "    密码（至少 8 位）Mot de passe : " ADMIN_PASSWORD < /dev/tty; echo
      [ "${#ADMIN_PASSWORD}" -ge 8 ] && break; echo "    密码至少 8 位"
    done
  fi
  payload="$(jq -n --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASSWORD" --arg n "${ADMIN_NAME:-Admin}" \
    '{email:$e, password:$p, email_confirm:true, user_metadata:{full_name:$n, lang:"zh"}}')"
  svc="$(env_get SERVICE_ROLE_KEY)"
  resp="$(curl -sS -X POST http://127.0.0.1:8000/auth/v1/admin/users \
           -H "apikey: $svc" -H "Authorization: Bearer $svc" -H "Content-Type: application/json" -d "$payload")"
  echo "$resp" | jq -e '.id' >/dev/null 2>&1 || die "创建管理员失败：$resp"
  ok "管理员已创建：$ADMIN_EMAIL"
else
  ok "已有 $users 个账号，跳过"
fi

chmod +x "$DEPLOY_DIR"/*.sh
cat > /etc/cron.d/leave-backup <<EOF
# 员工休假系统：每天 02:30 备份数据库和附件，保留 14 天
30 2 * * * root bash $DEPLOY_DIR/backup.sh >> $LEAVE_BASE/backup.log 2>&1
EOF
ok "每日自动备份：$LEAVE_BASE/backups"

# ---------------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32m')部署完成 / Déploiement terminé$(printf '\033[0m')

  网址 / Adresse      : $PUBLIC_URL
  管理员 / Admin      : 用刚才创建的邮箱和密码登录

  ⚠ 请阿里云账号管理员在 ECS 安全组放行 TCP 80 端口（入方向），否则外部无法访问。

  数据库管理后台（Studio，不对外开放）：
    在自己电脑上运行  ssh -L 8000:127.0.0.1:8000 root@${PUBLIC_URL#http://}
    然后浏览器打开    http://localhost:8000
    用户名 $(env_get DASHBOARD_USERNAME)，密码见 $SB_DIR/.env 中的 DASHBOARD_PASSWORD

  以后更新系统：sudo bash $DEPLOY_DIR/update.sh
  全部密钥保存在：$SB_DIR/.env（请妥善保管，勿外传）
EOF
