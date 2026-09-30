#!/usr/bin/env bash
# 员工休假系统 — 备份数据库和附件（每天由 cron 自动运行，保留 14 天）
# Sauvegarde de la base et des justificatifs (quotidienne, conservée 14 jours)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BK="$LEAVE_BASE/backups"
KEEP_DAYS="${KEEP_DAYS:-14}"
ts="$(date +%Y%m%d_%H%M)"
mkdir -p "$BK" && chmod 700 "$BK"

docker exec supabase-db pg_dump -U postgres -h 127.0.0.1 -d postgres -Fc \
  -n public -n auth -n storage -n leave_admin > "$BK/db_$ts.dump.tmp"
mv "$BK/db_$ts.dump.tmp" "$BK/db_$ts.dump"
tar czf "$BK/files_$ts.tar.gz" -C "$SB_DIR/volumes" storage
find "$BK" -type f \( -name 'db_*.dump' -o -name 'files_*.tar.gz' \) -mtime +"$KEEP_DAYS" -delete

ok "备份完成：$BK/db_$ts.dump（$(du -h "$BK/db_$ts.dump" | cut -f1)），$BK/files_$ts.tar.gz"
