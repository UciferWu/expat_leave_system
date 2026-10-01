-- =====================================================================
-- 011 — 邮件提醒按"操作记录"逐条发送
--       Notifications e-mail par événement (soumission, décision, modification, annulation)
-- 可重复运行 / ré-exécutable
-- =====================================================================
alter table public.leave_events add column if not exists notified_at timestamptz;

-- 本脚本运行之前的历史记录视为已通知，避免上线后补发大量旧邮件
-- Les événements antérieurs sont considérés comme déjà notifiés
update public.leave_events set notified_at = coalesce(notified_at, created_at) where notified_at is null
  and created_at < now();

-- 邮件函数需要查询余额（以服务端身份）/ La fonction e-mail lit les soldes
grant execute on function public._leave_balance(uuid, int, text) to service_role;
