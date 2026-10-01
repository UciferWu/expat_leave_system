#!/usr/bin/env bash
# =====================================================================
# 员工休假系统 — 配置邮件提醒（交互式），完成后自动发送一封测试邮件
# Configuration des notifications e-mail (interactive) + e-mail de test
#
#   bash /opt/leave/app/deploy/aliyun/mail-setup.sh
#
# 推荐用公司邮箱的 SMTP 发信：只需一个邮箱账号和密码 / 客户端授权码，无需修改域名解析。
# 注意：阿里云 ECS 默认禁止 25 端口外发，请使用 465 或 587。
# =====================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
[ -f "$SB_DIR/.env" ] || die "尚未安装休假系统，请先运行 install.sh"

ask()  { local v; read -rp "    $1 " v < /dev/tty; printf '%s' "$v"; }
asks() { local v; read -rsp "    $1 " v < /dev/tty; echo >&2; printf '%s' "$v"; }

log "选择发信方式 / Mode d'envoi"
cat <<'EOF'
    1) 阿里企业邮箱          smtp.qiye.aliyun.com:465
    2) 腾讯企业邮箱          smtp.exmail.qq.com:465
    3) 网易企业邮箱          smtphz.qiye.163.com:465
    4) Microsoft 365         smtp.office365.com:587
    5) Gmail / Google Workspace  smtp.gmail.com:465（需"应用专用密码"）
    6) 其他邮箱（手动填写 SMTP 服务器）
    7) Resend（需已验证发信域名和 API Key）
EOF
choice="$(ask "请输入序号 [1-7]:")"
host=""; port=""
case "$choice" in
  1) host=smtp.qiye.aliyun.com;  port=465 ;;
  2) host=smtp.exmail.qq.com;    port=465 ;;
  3) host=smtphz.qiye.163.com;   port=465 ;;
  4) host=smtp.office365.com;    port=587 ;;
  5) host=smtp.gmail.com;        port=465 ;;
  6) host="$(ask "SMTP 服务器地址:")"; port="$(ask "端口（465 或 587）[465]:")"; port="${port:-465}" ;;
  7) ;;
  *) die "无效的选择" ;;
esac

if [ "$choice" = 7 ]; then
  key="$(asks "Resend API Key（re_ 开头）:")"
  from="$(ask "发件人（例如 员工休假系统 <leave@mail.公司域名>）:")"
  [ -n "$key" ] && [ -n "$from" ] || die "API Key 和发件人都必须填写"
  env_set MAIL_SMTP_HOST ""; env_set MAIL_SMTP_PORT ""; env_set MAIL_SMTP_USER ""; env_set MAIL_SMTP_PASS ""
  env_set RESEND_API_KEY "'$key'"
  env_set MAIL_FROM "'$from'"
else
  [ -n "$host" ] || die "SMTP 服务器不能为空"
  printf '%s' "$port" | grep -Eq '^[0-9]+$' || die "端口必须是数字"
  [ "$port" != 25 ] || die "阿里云 ECS 禁止 25 端口外发，请改用 465 或 587"
  user="$(ask "发信邮箱账号（例如 leave@公司域名）:")"
  [ -n "$user" ] || die "邮箱账号不能为空"
  echo "    提示：很多企业邮箱需要在网页版设置里开启 SMTP 并生成\"客户端授权码 / 专用密码\"，这里填它。" >&2
  pass="$(asks "密码或授权码（输入时不显示）:")"
  [ -n "$pass" ] || die "密码不能为空"
  case "$pass$user" in *"'"*) die "密码中不能含单引号 '，请改用授权码或更换密码" ;; esac
  name="$(ask "发件人显示名称 [员工休假系统 / Congés]:")"; name="${name:-员工休假系统 / Congés}"
  env_set MAIL_SMTP_HOST "$host"
  env_set MAIL_SMTP_PORT "$port"
  env_set MAIL_SMTP_USER "'$user'"
  env_set MAIL_SMTP_PASS "'$pass'"
  env_set MAIL_FROM "'$name <$user>'"
  env_set RESEND_API_KEY ""
fi
chmod 600 "$SB_DIR/.env"
ok "已保存到 $SB_DIR/.env"

log "应用配置 / Application"
sync_app
compose up -d functions >/dev/null
wait_healthy "supabase-edge-functions" 120
sleep 3

log "发送测试邮件 / E-mail de test"
to="$(ask "测试邮件发到哪个邮箱:")"
[ -n "$to" ] || die "收件邮箱不能为空"
svc="$(env_get SERVICE_ROLE_KEY)"
resp="$(curl -sS -m 90 -X POST http://127.0.0.1:8000/functions/v1/notify-leave \
  -H "apikey: $svc" -H "Authorization: Bearer $svc" -H "Content-Type: application/json" \
  -d "$(jq -n --arg t "$to" '{test_to:$t, lang:"zh"}')" || true)"
if printf '%s' "$resp" | jq -e '.ok' >/dev/null 2>&1; then
  ok "测试邮件已发送到 $to，请查收（也请看一下垃圾邮件箱）"
  echo
  echo "    邮件提醒已启用：新申请会通知审批人，审批结果会通知申请人。"
else
  warn "发送失败：$resp"
  cat >&2 <<'EOF'

    常见原因：
      · 账号或授权码错误（很多企业邮箱必须用"客户端授权码"，不能用登录密码）
      · 邮箱后台未开启 SMTP / IMAP 服务
      · Microsoft 365 租户默认关闭了 SMTP 认证，需要管理员为该邮箱开启 "Authenticated SMTP"
    修正后重新运行本脚本即可。详细日志：docker logs --tail 50 supabase-edge-functions
EOF
  exit 1
fi
