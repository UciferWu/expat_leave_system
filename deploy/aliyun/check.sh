#!/usr/bin/env bash
# 员工休假系统 — 部署前检查（只读，不做任何修改）
# Vérification avant installation (lecture seule)
#   bash check.sh
ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
inf() { printf '  · %s\n' "$*"; }

echo "== 账号 / Compte"
if [ "$(id -u)" = 0 ]; then ok "root"; elif sudo -n true 2>/dev/null; then ok "$(id -un)（可免密 sudo）"; \
elif command -v sudo >/dev/null; then inf "$(id -un)：安装时需要 sudo（会要求输入密码）"; else bad "$(id -un)：不是 root，也没有 sudo，无法安装"; fi

echo "== 系统 / Système"
. /etc/os-release 2>/dev/null; inf "${PRETTY_NAME:-未知}"
mem=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
[ "$mem" -ge 3500 ] && ok "内存 ${mem} MB" || { [ "$mem" -ge 1700 ] && inf "内存 ${mem} MB（可以运行，会自动加交换空间）" || bad "内存 ${mem} MB（至少需要 2 GB）"; }
disk=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[ "$disk" -ge 10 ] && ok "磁盘可用 ${disk} GB" || bad "磁盘可用 ${disk} GB（至少需要 10 GB）"

echo "== 公网地址 / Adresse publique"
ip=$(curl -fsS -m 3 http://100.100.100.200/latest/meta-data/eipv4 2>/dev/null || curl -fsS -m 3 http://100.100.100.200/latest/meta-data/public-ipv4 2>/dev/null)
[ -n "$ip" ] && ok "公网 IP：$ip" || bad "没有检测到公网 IP（员工将无法从外网访问，需要管理员绑定 EIP 或配置负载均衡）"
inf "内网 IP：$(hostname -I 2>/dev/null | awk '{print $1}')"

echo "== 外网访问 / Accès Internet"
for u in https://github.com https://raw.githubusercontent.com https://mirrors.aliyun.com https://registry-1.docker.io/v2/ https://esm.sh https://api.resend.com; do
  code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$u")
  case "$code" in 000) bad "$u 无法访问" ;; *) ok "$u（$code）" ;; esac
done

echo "== 已有软件 / Logiciels"
command -v git >/dev/null && ok "git" || inf "git 未安装（先运行：yum install -y git，或 dnf / apt install -y git）"
command -v docker >/dev/null && ok "$(docker --version)" || inf "Docker 未安装（安装脚本会自动安装）"

echo "== 端口 / Ports"
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE '(:|\.)80$'; then bad "80 端口已被占用：$(ss -ltnp 2>/dev/null | grep -E ':80 ' | head -1)"; else ok "80 端口空闲"; fi
systemctl is-active --quiet firewalld 2>/dev/null && inf "firewalld 已启用（安装脚本会自动放行 80 端口）"
command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active && inf "ufw 已启用（安装脚本会自动放行 80 端口）"
echo
echo "请把以上结果截图发给 Claude。"
