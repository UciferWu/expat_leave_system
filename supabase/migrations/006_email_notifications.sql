-- =====================================================================
-- 006 — 邮件通知 / Notifications par e-mail / Email notifications
-- 记录审批人邮件发送时间，防止重复发送（可重复运行）
-- =====================================================================
alter table public.leave_requests add column if not exists notified_at timestamptz;
