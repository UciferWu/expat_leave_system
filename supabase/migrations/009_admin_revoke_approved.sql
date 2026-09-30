-- =====================================================================
-- 009 — 已批准的申请只有管理员可以撤销（须填写原因）
--       Seul un administrateur peut révoquer un congé approuvé (motif obligatoire)
--       Only an administrator can revoke approved leave (reason required)
-- 在 008 之后运行，可重复运行 / À exécuter après 008 (ré-exécutable)
-- =====================================================================
create or replace function public.cancel_leave(p_id uuid, p_comment text default null)
returns public.leave_requests
language plpgsql security definer set search_path = public as $$
declare me public.profiles; r public.leave_requests;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.active then raise exception 'ERR_ACCOUNT_INACTIVE'; end if;

  select * into r from public.leave_requests where id = p_id for update;
  if r.id is null then raise exception 'ERR_NOT_FOUND'; end if;

  if r.status = 'pending' then
    -- 待审批：员工本人或管理员可撤回 / en attente : le salarié ou un administrateur
    if not (r.user_id = me.id or me.role = 'admin') then raise exception 'ERR_FORBIDDEN'; end if;
  elsif r.status = 'approved' then
    -- 已批准：仅管理员可撤销，且须填写原因 / approuvée : administrateur uniquement, motif obligatoire
    if me.role <> 'admin' then raise exception 'ERR_NOT_CANCELLABLE'; end if;
    if coalesce(trim(p_comment), '') = '' then raise exception 'ERR_COMMENT_REQUIRED'; end if;
  else
    raise exception 'ERR_NOT_CANCELLABLE';
  end if;

  update public.leave_requests
     set status = 'cancelled', decided_by = me.id, decided_by_name = me.full_name, decided_at = now(),
         decision_comment = coalesce(nullif(trim(p_comment), ''), decision_comment)
   where id = p_id
  returning * into r;

  insert into public.leave_events (request_id, actor_id, actor_name, action, comment)
  values (r.id, me.id, me.full_name, 'cancelled', nullif(trim(p_comment), ''));
  return r;
end $$;
