#!/usr/bin/env bash
# =====================================================================
# 恢复员工休假系统，不触碰人力报告平台
#
# 背景（2026-10-14）：人力报告平台的 Supabase（/opt/supabase/docker）与休假系统都使用
# 官方默认的项目名 supabase 和容器名 supabase-*，人力报告平台启动时替换了休假系统的
# 数据库、登录、网关等容器。休假数据完好地保存在 /opt/leave/supabase/volumes/db/data。
#
# 本脚本让休假系统改用独立的项目名 leave 和容器名 leave-*，重新连接自己的数据库：
#   - 人力报告平台的容器一个都不停、不重启、不修改
#   - 休假系统的网址、账号、数据都不变
#
# 用法（root）：
#   cd /opt/leave/app && git pull
#   bash /opt/leave/app/deploy/fix/restore-leave.sh
# =====================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../aliyun/lib.sh"
require_root

TS="$(date +%Y%m%d_%H%M%S)"
BK="$LEAVE_BASE/backups/before-restore-$TS"
label() { docker inspect "$1" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null || true; }
http_code() { curl -s -o /dev/null -m 15 -w '%{http_code}' "$@" || true; }
hr_snapshot() {  # 人力报告平台容器的 ID 和启动时间，用于确认没有被改动
  local c
  for c in $(docker ps -a --format '{{.Names}}' | sort); do
    case "$(label "$c" com.docker.compose.project.working_dir)" in
      "$SB_DIR") ;;  # 休假系统自己的容器
      *) case "$c" in gateway-caddy) ;; *) docker inspect "$c" --format '{{.Name}} {{.Id}} {{.State.StartedAt}} {{.State.Status}}' ;; esac ;;
    esac
  done
}

# =====================================================================
log "0/5 预检查（只读）"
[ -f "$SB_DIR/.env" ] || die "找不到 $SB_DIR/.env"
[ -s "$SB_DIR/volumes/db/data/PG_VERSION" ] || die "休假数据目录 $SB_DIR/volumes/db/data 不完整"
for c in $(docker ps -aq); do
  docker inspect "$c" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' | grep -qx "$SB_DIR/volumes/db/data" \
    && die "休假数据目录正被容器 $(docker inspect "$c" --format '{{.Name}}') 使用，现状与诊断不符，未做任何改动"
done
ok "休假数据目录完好（$(du -sh "$SB_DIR/volumes/db/data" | cut -f1)），未被任何容器占用"

LEAVE_OLD=()
for c in $(docker ps -a --format '{{.Names}}'); do
  [ "$(label "$c" com.docker.compose.project.working_dir)" = "$SB_DIR" ] && LEAVE_OLD+=("$c")
done
ok "休假系统现有容器：${LEAVE_OLD[*]:-（无）}"

for c in leave-db leave-auth leave-rest leave-storage leave-studio leave-envoy leave-functions leave-meta leave-imgproxy; do
  if docker inspect "$c" >/dev/null 2>&1 && [ "$(label "$c" com.docker.compose.project.working_dir)" != "$SB_DIR" ]; then
    die "容器名 $c 已被其他程序使用，未做任何改动"
  fi
done
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$LEAVE_API_PORT\$"; then
  docker ps --format '{{.Names}} {{.Ports}}' | grep -q "^leave-envoy .*:$LEAVE_API_PORT->" || die "本机端口 $LEAVE_API_PORT 已被占用"
fi

HR_BEFORE="$(hr_snapshot)"
hr_code_before="$(http_code https://hrwork.winninggroup.top/)"
ok "人力报告平台当前状态已记录（网页 HTTP $hr_code_before）"

echo
echo "    休假系统将改用独立的容器（leave-*），约 2–5 分钟。人力报告平台不受影响。"
read -rp "    现在继续吗？输入 yes 继续：" ans < /dev/tty
[ "$ans" = "yes" ] || die "已取消，未做任何改动"

# =====================================================================
log "1/5 备份休假数据 → $BK"
mkdir -p "$BK" && chmod 700 "$BK"
cp -a "$SB_DIR/.env" "$BK/leave.env"
tar czf "$BK/db_data.tar.gz" -C "$SB_DIR/volumes/db" data
tar czf "$BK/storage.tar.gz" -C "$SB_DIR/volumes" storage
ok "$(du -sh "$BK" | cut -f1)"

# =====================================================================
log "2/5 更新休假系统配置（独立项目名 leave，接口本机端口 $LEAVE_API_PORT）"
env_set COMPOSE_PROJECT_NAME "leave"
env_set API_GW_HTTP_PORT     "127.0.0.1:$LEAVE_API_PORT"
sync_app
compose config -q || { cp -a "$BK/leave.env" "$SB_DIR/.env"; die "配置校验失败，已还原，未停止任何服务"; }
ok "配置已更新"

# 数据库的附加配置卷（含加密根密钥）复制一份给新项目（只读取原卷，不改动）
if ! docker volume inspect leave_db-config >/dev/null 2>&1 && docker volume inspect supabase_db-config >/dev/null 2>&1; then
  img="$(compose config --images 2>/dev/null | grep "supabase/postgres" | head -1)"; img="${img:-supabase/postgres:17.6.1.136}"
  docker volume create leave_db-config >/dev/null
  docker run --rm --entrypoint sh -v supabase_db-config:/from:ro -v leave_db-config:/to "$img" -c 'cp -a /from/. /to/' \
    && ok "数据库配置卷已复制" || warn "数据库配置卷复制失败（一般不影响使用）"
fi

# =====================================================================
log "3/5 用新的容器名启动休假系统"
if [ "${#LEAVE_OLD[@]}" -gt 0 ]; then
  docker rm -f "${LEAVE_OLD[@]}" >/dev/null
  ok "已移除旧容器：${LEAVE_OLD[*]}（数据目录不受影响）"
fi
compose up -d
wait_healthy "$LEAVE_CORE" 600

# =====================================================================
log "4/5 检查休假系统"
anon="$(env_get ANON_KEY)"
code="$(http_code -H "apikey: $anon" "http://127.0.0.1:8081/auth/v1/health")"
[ "$code" = 200 ] || die "休假系统登录服务 HTTP $code。备份在 $BK"
users="$(db_sql -tA -c 'select count(*) from public.profiles')"
reqs="$(db_sql -tA -c 'select count(*) from public.leave_requests' 2>/dev/null || echo '?')"
ok "数据库已连接：账号 $users 个，休假申请 $reqs 条"
pub="$(env_get SUPABASE_PUBLIC_URL)"
code="$(http_code -H "apikey: $anon" "$pub/auth/v1/health")"
[ "$code" = 200 ] && ok "$pub 正常" || warn "$pub 返回 HTTP $code"

# =====================================================================
log "5/5 确认人力报告平台没有被改动"
HR_AFTER="$(hr_snapshot)"
if [ "$HR_BEFORE" = "$HR_AFTER" ]; then
  ok "人力报告平台的容器全部保持原样（未停止、未重启）"
else
  warn "人力报告平台的容器状态有变化："
  diff <(printf '%s\n' "$HR_BEFORE") <(printf '%s\n' "$HR_AFTER") | sed 's/^/      /' || true
fi
hr_code_after="$(http_code https://hrwork.winninggroup.top/)"
ok "人力报告平台网页 HTTP $hr_code_after（之前 $hr_code_before）"

cat <<EOF

$(printf '\033[1;32m')休假系统已恢复$(printf '\033[0m')
  网址：$pub （账号和数据不变）
  以后的更新、备份、邮件设置脚本照常使用（已改用新的容器名 leave-*）
  数据库管理后台（Studio）：SSH 隧道改为转发 127.0.0.1:$LEAVE_API_PORT
  恢复前的备份：$BK
EOF
