#!/usr/bin/env bash
# =====================================================================
# 修复：人力报告平台（/opt/supabase/docker）占用了员工休假系统的容器名
#
# 现状（2026-10-14 诊断）：
#   - 两套 Supabase 都使用官方默认项目名 "supabase" 和默认容器名，
#     人力报告平台启动时替换了休假系统的 supabase-db / auth / rest / envoy / studio，
#     休假系统因此无法登录。休假数据完好地保存在 /opt/leave/supabase/volumes/db/data。
#   - 人力报告平台使用 Supabase 官方公开的默认 JWT 密钥，且接口和 Studio
#     通过 supabase.winninggroup.top 及 hrwork.../api/ 对外开放 —— 任何人都可伪造管理员身份。
#
# 本脚本：
#   0. 只读预检查（任何一项不符合就停止，不做改动）
#   1. 备份：人力报告平台数据库（pg_dump）、两套配置、休假数据目录
#   2. 为人力报告平台生成新的随机密钥（用户密码不变；所有人需重新登录一次）
#   3. 人力报告平台改用独立的项目名 hr、容器名 hr-*，接口只在本机 127.0.0.1:8100
#      （停机约 1–3 分钟；失败会自动恢复到原状态）
#   4. 休假系统重新连接自己的数据库
#   5. 关闭对外暴露的接口 / Studio（supabase.winninggroup.top、hrwork.../api/）
#   6. 检查两套系统
#
# 用法（root）：
#   cd /opt/leave/app && git pull
#   bash /opt/leave/app/deploy/fix/split-hr-from-leave.sh
# =====================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../aliyun/lib.sh"
require_root

HR_SB=/opt/supabase/docker          # 人力报告平台的 Supabase
HR_WEB_DIR=/opt/hr-platform         # 人力报告平台的网页（hr-web）
LEAVE_SB=/opt/leave/supabase        # 员工休假系统
GW=/opt/gateway
HR_API_PORT=8100
HR_DOMAIN="${HR_DOMAIN:-hrwork.winninggroup.top}"
TS="$(date +%Y%m%d_%H%M%S)"
BK="/opt/split-backup-$TS"

label() { docker inspect "$1" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null || true; }
hr_env_get() { SB_DIR="$HR_SB" env_get "$1"; }
hr_env_set() { SB_DIR="$HR_SB" env_set "$1" "$2"; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt_sign() {  # $1 = role, $2 = secret
  local now exp h p s
  now=$(date +%s); exp=$((now + 10 * 365 * 24 * 3600))
  h=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
  p=$(printf '{"role":"%s","iss":"supabase","iat":%d,"exp":%d}' "$1" "$now" "$exp" | b64url)
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -hmac "$2" -binary | b64url)
  printf '%s.%s.%s' "$h" "$p" "$s"
}
http_code() { curl -s -o /dev/null -m 15 -w '%{http_code}' "$@" || true; }

# =====================================================================
log "0/6 预检查（只读）"
[ -f "$HR_SB/.env" ] && [ -f "$HR_SB/docker-compose.yml" ] || die "找不到 $HR_SB/.env"
[ -f "$LEAVE_SB/.env" ] || die "找不到 $LEAVE_SB/.env"
[ -f "$HR_WEB_DIR/index.html" ] && [ -f "$HR_WEB_DIR/docker-compose.yml" ] || die "找不到 $HR_WEB_DIR"
command -v openssl >/dev/null || die "没有 openssl"

# 当前占用 supabase-* 名称的人力报告平台容器
HR_OLD=()
for c in $(docker ps -a --format '{{.Names}}'); do
  [ "$(label "$c" com.docker.compose.project.working_dir)" = "$HR_SB" ] && HR_OLD+=("$c")
done
[ "${#HR_OLD[@]}" -gt 0 ] || die "没有找到来自 $HR_SB 的容器，现状与诊断不符，未做任何改动"
HR_OLD_SERVICES=()
for c in "${HR_OLD[@]}"; do HR_OLD_SERVICES+=("$(label "$c" com.docker.compose.service)"); done
ok "人力报告平台当前容器：${HR_OLD[*]}（服务：${HR_OLD_SERVICES[*]}）"
[ "$(label supabase-db com.docker.compose.project.working_dir)" = "$HR_SB" ] || die "supabase-db 不属于 $HR_SB，现状与诊断不符，未做任何改动"

# 休假数据目录没有被任何容器使用
for c in $(docker ps -aq); do
  docker inspect "$c" --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' | grep -qx "$LEAVE_SB/volumes/db/data" \
    && die "休假数据目录正被容器 $(docker inspect "$c" --format '{{.Name}}') 使用，现状与诊断不符"
done
[ -s "$LEAVE_SB/volumes/db/data/PG_VERSION" ] || die "休假数据目录 $LEAVE_SB/volumes/db/data 不完整"
ok "休假数据目录完好且未被占用"

# 人力报告平台网页中的连接设置可以被自动修改
n_url=$(grep -cE '^[[:space:]]*const SUPABASE_URL[[:space:]]*=' "$HR_WEB_DIR/index.html" || true)
n_key=$(grep -cE '^[[:space:]]*const SUPABASE_KEY[[:space:]]*=' "$HR_WEB_DIR/index.html" || true)
[ "$n_url" = 1 ] && [ "$n_key" = 1 ] || die "$HR_WEB_DIR/index.html 中没有找到唯一的 SUPABASE_URL / SUPABASE_KEY 定义，未做任何改动"
ok "网页连接设置：$(grep -E '^[[:space:]]*const SUPABASE_URL' "$HR_WEB_DIR/index.html" | sed 's/^[[:space:]]*//' | cut -c1-90)"
if grep -q 'supabase\.winninggroup\.top' "$HR_WEB_DIR/index.html"; then
  warn "index.html 中其他位置还引用了 supabase.winninggroup.top，请事后检查（将关闭该地址）"
fi

# 人力报告平台服务名
HR_SERVICES="$(cd "$HR_SB" && COMPOSE_FILE=docker-compose.yml docker compose -p hr config --services 2>/dev/null)" \
  || die "无法读取 $HR_SB 的 compose 配置"
GW_SVC=""; for s in api-gw kong envoy; do printf '%s\n' "$HR_SERVICES" | grep -qx "$s" && { GW_SVC="$s"; break; }; done
[ -n "$GW_SVC" ] || die "没有找到网关服务（api-gw / kong）"
START_SVCS=""
for s in db auth rest "$GW_SVC" studio storage imgproxy meta functions; do
  printf '%s\n' "$HR_SERVICES" | grep -qx "$s" && START_SVCS="$START_SVCS $s"
done
ok "将启动的人力报告平台服务：$START_SVCS"

DB_IMAGE="$(docker inspect supabase-db --format '{{.Config.Image}}')"
hr_users_before="$(docker exec supabase-db psql -U postgres -h 127.0.0.1 -d postgres -tAc 'select count(*) from auth.users')"
ok "人力报告平台账号数：$hr_users_before"

echo
echo "    预检查通过。接下来人力报告平台会中断约 1–3 分钟，所有用户需要重新登录一次（密码不变）。"
read -rp "    现在继续吗？输入 yes 继续：" ans < /dev/tty
[ "$ans" = "yes" ] || die "已取消，未做任何改动"

# =====================================================================
log "1/6 备份 → $BK"
mkdir -p "$BK" && chmod 700 "$BK"
docker exec supabase-db pg_dump -U postgres -h 127.0.0.1 -d postgres -Fc -n public -n auth -n storage > "$BK/hr_db.dump" \
  || die "人力报告平台数据库备份失败，未做任何改动"
ok "人力报告平台数据库：$(du -h "$BK/hr_db.dump" | cut -f1)"
cp -a "$HR_SB/.env" "$BK/hr.env"
cp -a "$HR_WEB_DIR" "$BK/hr-platform"
cp -a "$LEAVE_SB/.env" "$BK/leave.env"
cp -a "$GW/sites" "$BK/gateway-sites"
tar czf "$BK/leave_db_data.tar.gz" -C "$LEAVE_SB/volumes/db" data
ok "休假数据目录：$(du -h "$BK/leave_db_data.tar.gz" | cut -f1)"
[ -d "$HR_SB/volumes/storage" ] && tar czf "$BK/hr_storage.tar.gz" -C "$HR_SB/volumes" storage && ok "人力报告平台附件目录已备份"

# 恢复到脚本运行前的状态（人力报告平台以原方式运行）
rollback() {
  warn "出现问题，正在把人力报告平台恢复到原来的状态……"
  docker ps -a --format '{{.Names}}' | grep -E '^hr-' | grep -vx hr-web | xargs -r docker rm -f >/dev/null 2>&1 || true
  cp -a "$BK/hr.env" "$HR_SB/.env"
  rm -f "$HR_SB/docker-compose.hr-split.yml"
  cp -a "$BK/hr-platform/." "$HR_WEB_DIR/"
  # 休假系统的同名容器先移开，让人力报告平台恢复原名
  for c in supabase-db supabase-auth supabase-rest supabase-envoy supabase-kong supabase-studio; do
    [ "$(label "$c" com.docker.compose.project.working_dir)" = "$LEAVE_SB" ] && docker rm -f "$c" >/dev/null 2>&1 || true
  done
  (cd "$HR_SB" && docker compose -p supabase up -d "${HR_OLD_SERVICES[@]}") || true
  (cd "$HR_WEB_DIR" && docker compose up -d --force-recreate) || true
  cp -a "$BK/gateway-sites/." "$GW/sites/"
  docker exec gateway-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
  die "已恢复原状态（人力报告平台照常运行，休假系统仍无法登录）。请把上面的输出发给 Claude。备份在 $BK"
}

# =====================================================================
log "2/6 为人力报告平台生成新的随机密钥"
new_secret="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-48)"
[ "${#new_secret}" -ge 40 ] || die "密钥生成失败"
new_anon="$(jwt_sign anon "$new_secret")"
new_service="$(jwt_sign service_role "$new_secret")"
hr_env_set JWT_SECRET "$new_secret"
hr_env_set ANON_KEY "$new_anon"
hr_env_set SERVICE_ROLE_KEY "$new_service"
hr_env_set DASHBOARD_PASSWORD "$(openssl rand -hex 16)"
# 新版密钥（如有）基于旧密钥生成，一并清空，改用上面的新密钥
for k in JWT_KEYS JWT_JWKS SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY ANON_KEY_ASYMMETRIC SERVICE_ROLE_KEY_ASYMMETRIC; do
  grep -qE "^$k=" "$HR_SB/.env" && hr_env_set "$k" ""
done
# 独立的项目名、本机端口、正确的网址
hr_env_set COMPOSE_PROJECT_NAME "hr"
hr_env_set COMPOSE_FILE "docker-compose.yml:docker-compose.hr-split.yml"
hr_env_set API_GW_HTTP_PORT "127.0.0.1:$HR_API_PORT"
grep -qE '^KONG_HTTP_PORT=' "$HR_SB/.env" && hr_env_set KONG_HTTP_PORT "127.0.0.1:$HR_API_PORT"
grep -qE '^KONG_HTTPS_PORT=' "$HR_SB/.env" && hr_env_set KONG_HTTPS_PORT "127.0.0.1:8543"
hr_env_set SUPABASE_PUBLIC_URL "https://$HR_DOMAIN"
hr_env_set API_EXTERNAL_URL "https://$HR_DOMAIN/auth/v1"
hr_env_set SITE_URL "https://$HR_DOMAIN"
hr_env_set ADDITIONAL_REDIRECT_URLS "https://$HR_DOMAIN/**,https://hr.winninggroup.top/**"
chmod 600 "$HR_SB/.env"

{
  echo "# 由 split-hr-from-leave.sh 生成：人力报告平台使用独立的项目名和容器名，避免与员工休假系统冲突"
  echo "name: hr"
  echo "services:"
  for s in $HR_SERVICES; do
    printf '  %s:\n    container_name: hr-%s\n' "$s" "$s"
  done
} > "$HR_SB/docker-compose.hr-split.yml"
(cd "$HR_SB" && docker compose -p hr config -q) || { cp -a "$BK/hr.env" "$HR_SB/.env"; rm -f "$HR_SB/docker-compose.hr-split.yml"; die "新配置校验失败，已还原配置，未停止任何服务"; }

# 网页使用新密钥、同源地址
ANON="$new_anon" awk '
  /^[[:space:]]*const SUPABASE_URL[[:space:]]*=/ { print "const SUPABASE_URL = window.location.origin;"; next }
  /^[[:space:]]*const SUPABASE_KEY[[:space:]]*=/ { print "const SUPABASE_KEY = \x27" ENVIRON["ANON"] "\x27;"; next }
  { print }' "$BK/hr-platform/index.html" > "$HR_WEB_DIR/index.html.new"
# hr-web 加入人力报告平台自己的网络
sed -i 's/supabase_default/hr_default/g' "$HR_WEB_DIR/docker-compose.yml"
ok "新密钥和配置已写入（旧密钥立即失效）"

# =====================================================================
log "3/6 人力报告平台切换到独立容器（hr-*）"
# 数据库的附加配置卷（含加密根密钥）复制一份给新项目
docker volume inspect hr_db-config >/dev/null 2>&1 || {
  docker volume create hr_db-config >/dev/null
  docker run --rm --entrypoint sh -v supabase_db-config:/from:ro -v hr_db-config:/to "$DB_IMAGE" -c 'cp -a /from/. /to/' \
    || warn "数据库配置卷复制失败（一般不影响使用）"
}
docker rm -f "${HR_OLD[@]}" >/dev/null
ok "旧容器已移除（数据目录不受影响）"
# shellcheck disable=SC2086
(cd "$HR_SB" && docker compose -p hr up -d $START_SVCS) || rollback
hr_wait=""
for s in db auth rest "$GW_SVC" storage; do printf '%s' "$START_SVCS" | grep -qw "$s" && hr_wait="$hr_wait hr-$s"; done
( wait_healthy "$hr_wait" 300 ) || rollback
mv -f "$HR_WEB_DIR/index.html.new" "$HR_WEB_DIR/index.html"
(cd "$HR_WEB_DIR" && docker compose up -d --force-recreate) || rollback
nets="$(docker inspect hr-web --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}')"
case " $nets " in *" hr_default "*) ;; *)
  docker network connect hr_default hr-web && docker restart hr-web >/dev/null || rollback ;;
esac
sleep 3
code="$(http_code -H "apikey: $new_anon" "http://127.0.0.1:8082/auth/v1/health")"
[ "$code" = 200 ] || { warn "人力报告平台网页接口 HTTP $code"; rollback; }
hr_users_after="$(docker exec hr-db psql -U postgres -h 127.0.0.1 -d postgres -tAc 'select count(*) from auth.users')"
[ "$hr_users_after" = "$hr_users_before" ] || { warn "账号数不一致：$hr_users_before → $hr_users_after"; rollback; }
ok "人力报告平台已恢复运行（账号 $hr_users_after 个）"

# =====================================================================
log "4/6 员工休假系统重新连接自己的数据库"
(cd "$LEAVE_SB" && docker compose up -d) || die "休假系统启动失败（人力报告平台不受影响）。备份在 $BK"
wait_healthy "supabase-db supabase-auth supabase-rest supabase-storage supabase-envoy supabase-edge-functions leave-web" 600
# 这几个容器在冲突期间连到了人力报告平台的数据库，重启以重新连接
docker restart supabase-storage supabase-edge-functions supabase-meta supabase-imgproxy leave-web >/dev/null
wait_healthy "supabase-storage supabase-edge-functions leave-web" 300
leave_anon="$(SB_DIR="$LEAVE_SB" env_get ANON_KEY)"
code="$(http_code -H "apikey: $leave_anon" "http://127.0.0.1:8081/auth/v1/health")"
[ "$code" = 200 ] || die "休假系统接口 HTTP $code（人力报告平台不受影响）。备份在 $BK"
leave_users="$(db_sql -tA -c 'select count(*) from public.profiles' 2>/dev/null || echo '?')"
ok "休假系统已恢复（账号 $leave_users 个）"

# =====================================================================
log "5/6 关闭对外暴露的接口和 Studio"
mkdir -p "$BK/removed-sites"
[ -f "$GW/sites/supabase.caddy" ] && mv "$GW/sites/supabase.caddy" "$BK/removed-sites/"
if [ -f "$GW/sites/hrwork.caddy" ]; then
  cat > "$GW/sites/hrwork.caddy" <<EOF
# 人力报告平台（网页与接口同源；Studio 不对外开放）
$HR_DOMAIN {
	encode gzip
	request_body {
		max_size 60MB
	}
	reverse_proxy 127.0.0.1:8082
}
EOF
fi
docker exec gateway-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null \
  || { cp -a "$BK/gateway-sites/." "$GW/sites/"; docker exec gateway-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1; warn "网关配置未能更新，已还原网关配置"; }
ok "supabase.winninggroup.top 与 /api/ 已关闭"

# =====================================================================
log "6/6 检查"
demo_service="$(jwt_sign service_role 'your-super-secret-jwt-token-with-at-least-32-characters-long')"  # 网上公开的默认密钥签出的管理员令牌
c1="$(http_code -H "apikey: $leave_anon" "https://leave.winninggroup.top/auth/v1/health")"
c2="$(http_code -H "apikey: $new_anon" "https://$HR_DOMAIN/auth/v1/health")"
c3="$(http_code -H "apikey: $new_anon" "https://hr.winninggroup.top/auth/v1/health")"
c4="$(http_code -H "apikey: $demo_service" -H "Authorization: Bearer $demo_service" "https://$HR_DOMAIN/rest/v1/sections?select=id&limit=1")"
c5="$(http_code "https://supabase.winninggroup.top/")"
printf '    休假系统  https://leave.winninggroup.top     : %s\n' "$c1"
printf '    人力报告  https://%s : %s\n' "$HR_DOMAIN" "$c2"
printf '    人力报告  https://hr.winninggroup.top        : %s\n' "$c3"
printf '    旧的公开默认密钥是否已失效（应为 401）      : %s\n' "$c4"
printf '    supabase.winninggroup.top 是否已关闭（应为 000）: %s\n' "$c5"
hr_files="$(docker exec hr-db psql -U postgres -h 127.0.0.1 -d postgres -tAc 'select count(*) from storage.objects' 2>/dev/null || echo '?')"

cat <<EOF

$(printf '\033[1;32m')完成$(printf '\033[0m')
  - 员工休假系统：已恢复，原有数据和账号不变
  - 人力报告平台：数据不变（账号 $hr_users_after 个，附件记录 $hr_files 条），已换成新的随机密钥；
    所有用户需要重新登录一次（密码不变）
  - 人力报告平台的 Studio：在自己电脑上用 SSH 隧道转发 127.0.0.1:$HR_API_PORT 后访问，
    新密码见 $HR_SB/.env 的 DASHBOARD_PASSWORD
  - 备份保存在：$BK（确认一切正常一周后可删除）
EOF
