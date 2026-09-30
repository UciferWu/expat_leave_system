-- =====================================================================
-- 010 — 多个附件 / Plusieurs justificatifs / Multiple attachments
-- 在 009 之后运行，可重复运行 / À exécuter après 009 (ré-exécutable)
-- =====================================================================
begin;

alter table public.leave_requests add column if not exists attachment_paths text[] not null default '{}';

-- 原有的单个附件并入列表 / reprise de l'ancien justificatif unique
update public.leave_requests
   set attachment_paths = array[attachment_path]
 where attachment_path is not null and attachment_path <> ''
   and not (attachment_path = any(attachment_paths));

-- 提交申请：p_attachments 为附件路径数组（最多 10 个）
-- Soumettre : p_attachments = liste des chemins (10 max)
drop function if exists public.submit_leave(text,date,date,boolean,boolean,text,text,text,text);
drop function if exists public.submit_leave(text,date,date,boolean,boolean,text,text,text,text[]);

create or replace function public.submit_leave(
  p_type text, p_start date, p_end date,
  p_start_half boolean default false, p_end_half boolean default false,
  p_reason text default null, p_destination text default null,
  p_contact text default null, p_attachments text[] default null
) returns public.leave_requests
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles; lt public.leave_types; st public.app_settings;
  n numeric; bal record; r public.leave_requests;
  atts text[] := coalesce(array_remove(p_attachments, ''), '{}'); a text;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.active then raise exception 'ERR_ACCOUNT_INACTIVE'; end if;
  select * into st from public.app_settings where id = 1;

  select * into lt from public.leave_types where code = p_type and active;
  if lt.code is null then raise exception 'ERR_TYPE'; end if;

  if p_start is null or p_end is null or p_end < p_start then raise exception 'ERR_DATES'; end if;
  if p_start = p_end and p_start_half and p_end_half then raise exception 'ERR_HALF'; end if;
  if extract(year from p_start)::int < st.first_year then
    raise exception 'ERR_BEFORE_START' using detail = st.first_year::text;
  end if;
  if p_start < current_date - 60 then raise exception 'ERR_TOO_OLD'; end if;
  if lt.balance_kind is not null and extract(year from p_start) <> extract(year from p_end) then
    raise exception 'ERR_CROSS_YEAR';
  end if;
  if lt.balance_kind = 'annual' and me.probation_end is not null and p_start <= me.probation_end then
    raise exception 'ERR_PROBATION' using detail = me.probation_end::text;
  end if;

  n := public.count_leave_days(p_start, p_end, p_start_half, p_end_half, me.work_country);
  if n <= 0 then raise exception 'ERR_ZERO_DAYS'; end if;

  if exists (select 1 from public.leave_requests x
              where x.user_id = me.id and x.status in ('pending','approved')
                and daterange(x.start_date, x.end_date, '[]') && daterange(p_start, p_end, '[]')) then
    raise exception 'ERR_OVERLAP';
  end if;

  if cardinality(atts) > 10 then raise exception 'ERR_TOO_MANY_FILES'; end if;
  foreach a in array atts loop
    if split_part(a, '/', 1) <> me.id::text then raise exception 'ERR_ATTACHMENT'; end if;
  end loop;
  if lt.requires_attachment and cardinality(atts) = 0 then raise exception 'ERR_ATTACHMENT_REQUIRED'; end if;

  if lt.balance_kind is not null then
    select * into bal from public._leave_balance(me.id, extract(year from p_start)::int, lt.balance_kind);
    if n > bal.available then
      raise exception 'ERR_BALANCE' using detail = bal.available::text, hint = lt.balance_kind;
    end if;
  end if;

  insert into public.leave_requests
    (ref_no, user_id, type_code, start_date, end_date, start_half, end_half, days,
     reason, destination, contact, attachment_path, attachment_paths, approver_id)
  values
    ('CG-' || extract(year from current_date)::int || '-' || lpad(nextval('public.leave_ref_seq')::text, 4, '0'),
     me.id, p_type, p_start, p_end, p_start_half, p_end_half, n,
     nullif(trim(p_reason), ''), nullif(trim(p_destination), ''), nullif(trim(p_contact), ''),
     atts[1], atts, me.approver_id)
  returning * into r;

  insert into public.leave_events (request_id, actor_id, actor_name, action)
  values (r.id, me.id, me.full_name, 'submitted');
  return r;
end $$;

revoke execute on function public.submit_leave(text,date,date,boolean,boolean,text,text,text,text[]) from public, anon;
grant  execute on function public.submit_leave(text,date,date,boolean,boolean,text,text,text,text[]) to authenticated;

-- 附件访问权限：审批人可查看该申请的所有附件
-- Accès aux justificatifs : le valideur voit tous les fichiers de la demande
drop policy if exists "leave_att_read" on storage.objects;
create policy "leave_att_read" on storage.objects for select to authenticated
  using (bucket_id = 'leave-attachments' and (
           (storage.foldername(name))[1] = auth.uid()::text
           or public.is_admin()
           or exists (select 1 from public.leave_requests r
                       where r.approver_id = auth.uid()
                         and (r.attachment_path = storage.objects.name
                              or storage.objects.name = any(r.attachment_paths)))));

drop policy if exists "leave_att_delete_own" on storage.objects;
create policy "leave_att_delete_own" on storage.objects for delete to authenticated
  using (bucket_id = 'leave-attachments'
         and (storage.foldername(name))[1] = auth.uid()::text
         and not exists (select 1 from public.leave_requests r
                          where r.attachment_path = storage.objects.name
                             or storage.objects.name = any(r.attachment_paths)));

commit;
