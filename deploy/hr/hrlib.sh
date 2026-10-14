#!/usr/bin/env bash
# 人力报告平台（HR_Reporting_Platform）— 部署脚本公共函数
# 在同一台服务器上运行第二套、完全独立的 Supabase（容器名前缀 hr-），与员工休假系统互不影响。

HR_BASE="${HR_BASE:-/opt/hr}"
HR_REPO_URL="${HR_REPO_URL:-https://github.com/UciferWu/HR_Reporting_Platform.git}"
HR_APP="$HR_BASE/app"            # 人力报告平台的代码（git clone）
HR_WEB_PORT="${HR_WEB_PORT:-8082}"   # 网页：只在本机开放，由网关转发
HR_API_PORT="${HR_API_PORT:-8100}"   # Supabase 接口 / Studio：只在本机开放
GW_DIR="${GW_DIR:-/opt/gateway}"

HR_DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 复用员工休假系统的通用函数（log/ok/warn/die/env_get/env_set/wait_healthy …）
source "$HR_DEPLOY_DIR/../aliyun/lib.sh"
LEAVE_SB_DIR="$SB_DIR"           # 休假系统的 Supabase 目录（只读取邮件设置）
SB_DIR="$HR_BASE/supabase"       # 之后 env_get / env_set 都作用于人力报告平台

HR_CONTAINERS="hr-db hr-auth hr-rest hr-storage hr-meta hr-studio hr-envoy hr-web"

hr_compose() { (cd "$SB_DIR" && docker compose -p hr "$@"); }

# 以 postgres 身份执行 SQL（与网页 SQL Editor 相同）
hr_sql() { docker exec -i hr-db psql -v ON_ERROR_STOP=1 -q -X -U postgres -h 127.0.0.1 -d postgres "$@"; }
# 以超级用户执行（导入数据、建触发器等需要）
hr_sql_admin() { docker exec -i hr-db psql -v ON_ERROR_STOP=1 -q -X -U supabase_admin -h 127.0.0.1 -d postgres "$@"; }

# 部署网页：把仓库里的 index.html 复制过来，并把连接地址 / 密钥换成本服务器的
# （仓库里的 index.html 可以继续保持连接 Supabase 云的配置，不影响 GitHub Pages 上的旧网址）
hr_sync_site() {
  local anon; anon="$(env_get ANON_KEY)"
  [ -n "$anon" ] || die ".env 中没有 ANON_KEY"
  [ -f "$HR_APP/index.html" ] || die "找不到 $HR_APP/index.html"
  mkdir -p "$SB_DIR/hr/site/mail"
  local out="$SB_DIR/hr/site/index.html"
  ANON="$anon" awk '
    /^[[:space:]]*const SUPABASE_URL[[:space:]]*=/ { print "const SUPABASE_URL = window.location.origin; // 由部署脚本设置"; u++; next }
    /^[[:space:]]*const SUPABASE_KEY[[:space:]]*=/ { print "const SUPABASE_KEY = \x27" ENVIRON["ANON"] "\x27; // 由部署脚本设置"; k++; next }
    { print }
    END { if (u != 1 || k != 1) exit 3 }
  ' "$HR_APP/index.html" > "$out.tmp" || { rm -f "$out.tmp"; die "index.html 中没有找到唯一的 SUPABASE_URL / SUPABASE_KEY 定义，无法自动设置"; }
  mv "$out.tmp" "$out"
  # 其他静态文件（如果以后仓库里增加了图片等）
  ( cd "$HR_APP" && find . -maxdepth 3 -type f ! -path './.git/*' ! -name index.html ! -name '*.md' -print0 \
      | while IFS= read -r -d '' f; do mkdir -p "$SB_DIR/hr/site/$(dirname "$f")"; cp -f "$f" "$SB_DIR/hr/site/$f"; done )
  cp -f "$HR_DEPLOY_DIR/mail/"*.html "$SB_DIR/hr/site/mail/"
  cp -f "$HR_DEPLOY_DIR/nginx.conf" "$SB_DIR/hr/nginx.conf"
  cp -f "$HR_DEPLOY_DIR/docker-compose.hr.yml" "$SB_DIR/docker-compose.hr.yml"
  ok "网页已部署（版本 $(git -C "$HR_APP" log -1 --format='%h %ad' --date=short 2>/dev/null)）"
}

hr_require_installed() {
  [ -f "$SB_DIR/.env" ] || die "人力报告平台尚未安装，请先运行：bash $HR_DEPLOY_DIR/install.sh hr.公司域名"
}
