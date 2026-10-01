#!/usr/bin/env bash
# 员工休假系统 — 部署脚本公共函数（由 install.sh / update.sh 引用）

LEAVE_BASE="${LEAVE_BASE:-/opt/leave}"
SB_DIR="$LEAVE_BASE/supabase"
SB_REF="${SB_REF:-self-hosted/v0.8.2}"
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$DEPLOY_DIR/../.." && pwd)"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    ✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31m错误 / Erreur : %s\033[0m\n' "$*" >&2; exit 1; }

require_root() { [ "$(id -u)" = 0 ] || die "请用 root 运行 / exécuter en root : sudo bash $0"; }

# 读取 / 写入 .env 中的变量
env_get() { grep -E "^$1=" "$SB_DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//"; }
env_set() {
  local key="$1" val="$2" f="$SB_DIR/.env"
  if grep -qE "^$key=" "$f"; then
    KEY="$key" VAL="$val" awk 'BEGIN{k=ENVIRON["KEY"]; v=ENVIRON["VAL"]} index($0, k"=")==1 {print k"="v; next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    printf '%s=%s\n' "$key" "$val" >> "$f"
  fi
}
# 只在变量不存在时写入（保留用户已填的值）
env_default() { grep -qE "^$1=" "$SB_DIR/.env" || printf '%s=%s\n' "$1" "$2" >> "$SB_DIR/.env"; }

compose() { (cd "$SB_DIR" && docker compose "$@"); }

db_sql() {  # 以 postgres 身份执行 SQL（与 Supabase 网页 SQL Editor 相同）
  docker exec -i supabase-db psql -v ON_ERROR_STOP=1 -q -X -U postgres -h 127.0.0.1 -d postgres "$@"
}

wait_healthy() {
  local deadline=$(( $(date +%s) + ${2:-600} )) c st
  for c in $1; do
    while :; do
      st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo missing)
      case "$st" in healthy|running) ok "$c: $st"; break ;; esac
      [ "$(date +%s)" -lt "$deadline" ] || { docker logs --tail 40 "$c" 2>&1 | sed 's/^/      /' >&2; die "$c 启动超时（状态：$st）"; }
      sleep 5
    done
  done
}

# 复制网页、函数和 Nginx 配置到部署目录
sync_app() {
  local anon; anon="$(env_get ANON_KEY)"
  [ -n "$anon" ] || die ".env 中没有 ANON_KEY"
  mkdir -p "$SB_DIR/leave/site/vendor"
  cp -f "$REPO_DIR/index.html" "$REPO_DIR/icon.svg" "$REPO_DIR/manifest.webmanifest" "$SB_DIR/leave/site/"
  cp -f "$REPO_DIR/vendor/"* "$SB_DIR/leave/site/vendor/"
  cat > "$SB_DIR/leave/site/config.js" <<EOF
// 由部署脚本自动生成 / Généré automatiquement — 网页与接口同源
window.APP_CONFIG = {
  SUPABASE_URL: location.origin,
  SUPABASE_ANON_KEY: "$anon",
};
EOF
  cp -f "$DEPLOY_DIR/nginx.conf" "$SB_DIR/leave/nginx.conf"
  cp -f "$DEPLOY_DIR/docker-compose.leave.yml" "$SB_DIR/docker-compose.leave.yml"
  local fn
  for fn in "$REPO_DIR"/supabase/functions/*/; do
    fn="$(basename "$fn")"
    rm -rf "$SB_DIR/volumes/functions/$fn"
    cp -r "$REPO_DIR/supabase/functions/$fn" "$SB_DIR/volumes/functions/$fn"
  done
  ok "网页、函数已同步"
}

# 按顺序执行尚未执行过的数据库脚本（记录在 leave_admin.migrations）
apply_migrations() {
  db_sql -c "create schema if not exists leave_admin; revoke all on schema leave_admin from public;
             create table if not exists leave_admin.migrations (name text primary key, applied_at timestamptz not null default now());" \
    || die "无法连接数据库"
  local f name done_count=0
  for f in "$REPO_DIR"/supabase/migrations/*.sql; do
    name="$(basename "$f")"
    if [ "$(db_sql -tA -c "select 1 from leave_admin.migrations where name = '$name'")" = "1" ]; then continue; fi
    printf '    → %s\n' "$name"
    db_sql < "$f" || die "数据库脚本 $name 执行失败"
    db_sql -c "insert into leave_admin.migrations(name) values ('$name')"
    done_count=$((done_count + 1))
  done
  db_sql < "$DEPLOY_DIR/grants.sql"
  ok "数据库脚本：新执行 $done_count 个"
}
