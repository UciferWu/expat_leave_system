-- =====================================================================
-- 012 — 按假期类型设置天数计算方式；病假按日历日计算；法语名称修正
--       Mode de décompte par type de congé (maladie : jours calendaires)
--       Day-count method per leave type (sick leave: calendar days)
--
-- 天数计算方式优先级：假期类型 > 工作国家 > 系统默认
-- 已提交的申请天数不变；只影响此后新提交或修改的申请。
-- =====================================================================
begin;

-- 1. 假期类型增加计算方式（留空 = 沿用工作国家 / 系统默认）
alter table public.leave_types add column if not exists count_mode text
  check (count_mode in ('ouvrables','ouvres','calendaires'));

update public.leave_types set count_mode = 'calendaires' where code = 'sick';

-- 2. 法语名称 / Libellés français
update public.leave_types set name_fr = 'Congé pour visite familiale au pays'          where code = 'home';
update public.leave_types set name_fr = 'Congé exceptionnel pour événements familiaux' where code = 'family';

-- 3. 天数计算：增加假期类型参数
drop function if exists public.count_leave_days(date, date, boolean, boolean, text);

create or replace function public.count_leave_days(
  p_start date, p_end date,
  p_start_half boolean default false, p_end_half boolean default false,
  p_country text default null, p_type text default null
) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare
  v_mode text; v_country text; d date; n numeric := 0; counted boolean;
begin
  if p_start is null or p_end is null or p_end < p_start then return 0; end if;
  if p_end - p_start > 366 then return 0; end if;
  v_country := coalesce(p_country,
                        (select pr.work_country from public.profiles pr where pr.id = auth.uid()),
                        'GN');
  -- 优先级：假期类型 > 工作国家 > 系统默认
  -- Priorité : type de congé > pays de travail > réglage par défaut
  select coalesce(t.count_mode, c.count_mode, s.count_mode) into v_mode
    from public.app_settings s
    left join public.countries c on c.code = v_country
    left join public.leave_types t on t.code = p_type
   where s.id = 1;

  for d in select g::date from generate_series(p_start, p_end, interval '1 day') g loop
    if v_mode = 'calendaires' then
      counted := true;
    elsif exists (select 1 from public.holidays h
                   where h.day = d and h.country_code = v_country and h.is_workday) then
      counted := true;                                  -- 调休上班 / jour travaillé exceptionnel
    elsif exists (select 1 from public.holidays h
                   where h.day = d and h.country_code = v_country and not h.is_workday) then
      counted := false;                                 -- 公共假期 / férié
    else
      counted := extract(isodow from d) < case when v_mode = 'ouvres' then 6 else 7 end;
    end if;
    if counted then
      n := n + case when (d = p_start and p_start_half) or (d = p_end and p_end_half) then 0.5 else 1 end;
    end if;
  end loop;
  return n;
end $$;

revoke execute on function public.count_leave_days(date,date,boolean,boolean,text,text) from public, anon;
grant  execute on function public.count_leave_days(date,date,boolean,boolean,text,text) to authenticated;

-- 4. 提交申请：按所选假期类型计算天数（其余逻辑与 010 相同）
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

  n := public.count_leave_days(p_start, p_end, p_start_half, p_end_half, me.work_country, p_type);
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

-- 5. 修改已批准的申请：按该申请的假期类型计算天数（其余逻辑与 004 相同）
create or replace function public.modify_leave(
  p_id uuid, p_start date, p_end date,
  p_start_half boolean default false, p_end_half boolean default false,
  p_comment text default null
) returns public.leave_requests
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles; emp public.profiles; st public.app_settings;
  r public.leave_requests; lt public.leave_types; bal record;
  n numeric; old_days numeric; own_in_year numeric;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.active then raise exception 'ERR_ACCOUNT_INACTIVE'; end if;
  select * into st from public.app_settings where id = 1;

  select * into r from public.leave_requests where id = p_id for update;
  if r.id is null then raise exception 'ERR_NOT_FOUND'; end if;
  if r.user_id = me.id then raise exception 'ERR_SELF_APPROVAL'; end if;
  if not (r.approver_id = me.id or me.role = 'admin') then raise exception 'ERR_FORBIDDEN'; end if;
  if r.status <> 'approved' then raise exception 'ERR_NOT_APPROVED'; end if;
  if coalesce(trim(p_comment), '') = '' then raise exception 'ERR_COMMENT_REQUIRED'; end if;

  select * into emp from public.profiles where id = r.user_id;
  select * into lt  from public.leave_types where code = r.type_code;

  if p_start is null or p_end is null or p_end < p_start then raise exception 'ERR_DATES'; end if;
  if p_start = p_end and p_start_half and p_end_half then raise exception 'ERR_HALF'; end if;
  if extract(year from p_start)::int < st.first_year then
    raise exception 'ERR_BEFORE_START' using detail = st.first_year::text;
  end if;
  if lt.balance_kind is not null and extract(year from p_start) <> extract(year from p_end) then
    raise exception 'ERR_CROSS_YEAR';
  end if;
  if lt.balance_kind = 'annual' and emp.probation_end is not null and p_start <= emp.probation_end then
    raise exception 'ERR_PROBATION' using detail = emp.probation_end::text;
  end if;
  if p_start = r.start_date and p_end = r.end_date
     and p_start_half = r.start_half and p_end_half = r.end_half then
    raise exception 'ERR_NO_CHANGE';
  end if;

  n := public.count_leave_days(p_start, p_end, p_start_half, p_end_half, emp.work_country, r.type_code);
  if n <= 0 then raise exception 'ERR_ZERO_DAYS'; end if;

  if exists (select 1 from public.leave_requests x
              where x.user_id = r.user_id and x.id <> r.id and x.status in ('pending','approved')
                and daterange(x.start_date, x.end_date, '[]') && daterange(p_start, p_end, '[]')) then
    raise exception 'ERR_OVERLAP';
  end if;

  if lt.balance_kind is not null then
    select * into bal from public._leave_balance(r.user_id, extract(year from p_start)::int, lt.balance_kind);
    -- 本申请原天数已计入 used（同一年时），先扣回再校验
    own_in_year := case when extract(year from r.start_date) = extract(year from p_start) then r.days else 0 end;
    if n > bal.total - (bal.used - own_in_year) then
      raise exception 'ERR_BALANCE' using detail = (bal.total - bal.used + own_in_year)::text, hint = lt.balance_kind;
    end if;
  end if;

  old_days := r.days;
  insert into public.leave_events (request_id, actor_id, actor_name, action, comment, details)
  values (r.id, me.id, me.full_name, 'modified', trim(p_comment),
          jsonb_build_object(
            'old', jsonb_build_object('start', r.start_date, 'end', r.end_date,
                                      'start_half', r.start_half, 'end_half', r.end_half, 'days', r.days),
            'new', jsonb_build_object('start', p_start, 'end', p_end,
                                      'start_half', p_start_half, 'end_half', p_end_half, 'days', n)));

  update public.leave_requests
     set start_date = p_start, end_date = p_end, start_half = p_start_half, end_half = p_end_half,
         days = n, modified_at = now()
   where id = r.id
  returning * into r;
  return r;
end $$;

revoke execute on function public.modify_leave(uuid,date,date,boolean,boolean,text) from public, anon;
grant  execute on function public.modify_leave(uuid,date,date,boolean,boolean,text) to authenticated;

commit;
