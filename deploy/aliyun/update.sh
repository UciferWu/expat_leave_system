#!/usr/bin/env bash
# =====================================================================
# 员工休假系统 — 更新到 GitHub 上的最新版本
# Mise à jour vers la dernière version publiée sur GitHub
#   sudo bash /opt/leave/app/deploy/aliyun/update.sh
# 会先备份，再更新网页、函数，并执行新的数据库脚本。
# =====================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_root
[ -f "$SB_DIR/.env" ] || die "尚未安装，请先运行 install.sh"

log "1/4 备份 / Sauvegarde"
bash "$DEPLOY_DIR/backup.sh"

log "2/4 获取最新代码 / Récupération du code"
before="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
git -C "$REPO_DIR" pull --ff-only -q || die "git pull 失败（本地文件是否被修改过？）"
after="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
ok "$before → $after"
# 脚本本身可能已更新，重新加载
source "$DEPLOY_DIR/lib.sh"

log "3/4 更新网页、函数和数据库 / Site, fonctions, base"
sync_app
compose up -d --remove-orphans
compose restart functions web >/dev/null
wait_healthy "supabase-db supabase-edge-functions leave-web" 300
apply_migrations

log "4/4 完成 / Terminé"
ok "网址：$(env_get SUPABASE_PUBLIC_URL)"
