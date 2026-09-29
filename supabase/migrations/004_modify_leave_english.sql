-- =====================================================================
-- 004 — 修改已批准的休假 + 英文界面
--       Modification d'un congé approuvé + interface en anglais
--       Editing approved leave + English interface
-- 在 SQL Editor 中整段运行一次（可重复运行）/ À exécuter une fois (ré-exécutable)
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. 英文 / English
-- ---------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_lang_check;
alter table public.profiles add constraint profiles_lang_check check (lang in ('zh','fr','en'));

alter table public.leave_types add column if not exists name_en text;
alter table public.countries   add column if not exists name_en text;
alter table public.holidays    add column if not exists name_en text;

update public.leave_types set name_en = v.n from (values
  ('annual','Annual leave'), ('home','Home leave'), ('sick','Sick leave'),
  ('family','Family event leave'), ('maternity','Maternity / paternity leave'),
  ('unpaid','Unpaid leave'), ('recovery','Time off in lieu')) v(c, n)
 where code = v.c and name_en is null;

update public.countries set name_en = v.n from (values
  ('CN','China'), ('GN','Guinea'), ('CI','Côte d''Ivoire'), ('SG','Singapore'), ('FR','France'),
  ('BE','Belgium'), ('CH','Switzerland'), ('CA','Canada'), ('LU','Luxembourg'), ('MC','Monaco'),
  ('SN','Senegal'), ('ML','Mali'), ('MA','Morocco'), ('TN','Tunisia'), ('DZ','Algeria'),
  ('CM','Cameroon'), ('SL','Sierra Leone'), ('LR','Liberia'), ('GH','Ghana'), ('GB','United Kingdom'),
  ('DE','Germany'), ('ES','Spain'), ('IT','Italy'), ('PT','Portugal'), ('US','United States'),
  ('AU','Australia')) v(c, n)
 where code = v.c and name_en is null;

update public.holidays set name_en = case name_fr
    when 'Jour de l''An' then 'New Year''s Day'
    when 'Lundi de Pâques' then 'Easter Monday'
    when 'Fête du Travail' then 'Labour Day'
    when 'Journée de l''Afrique' then 'Africa Day'
    when 'Assomption' then 'Assumption Day'
    when 'Fête de l''Indépendance' then 'Independence Day'
    when 'Toussaint' then 'All Saints'' Day'
    when 'Noël' then 'Christmas Day'
  end
 where name_en is null;

create or replace function public.set_my_lang(p_lang text) returns void
language sql security definer set search_path = public as $$
  update public.profiles set lang = p_lang
   where id = auth.uid() and p_lang in ('zh','fr','en');
$$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare is_first boolean;
begin
  select not exists (select 1 from public.profiles) into is_first;
  insert into public.profiles (id, email, full_name, lang, role, must_change_password)
  values (
    new.id, coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    case when new.raw_user_meta_data->>'lang' in ('zh','fr','en')
         then new.raw_user_meta_data->>'lang' else 'fr' end,
    case when is_first then 'admin' else 'employee' end,
    not is_first)
  on conflict (id) do nothing;
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 2. 修改记录 / Historique des modifications
-- ---------------------------------------------------------------------
alter table public.leave_events drop constraint if exists leave_events_action_check;
alter table public.leave_events add constraint leave_events_action_check
  check (action in ('submitted','approved','rejected','cancelled','modified'));
alter table public.leave_events    add column if not exists details jsonb;
alter table public.leave_requests  add column if not exists modified_at timestamptz;

-- ---------------------------------------------------------------------
-- 3. 修改已批准的休假（如提前结束）
--    Modifier un congé approuvé (ex. retour anticipé)
--    仅该申请的审批人或管理员可操作，必须填写原因；余额、重叠、试用期等规则重新校验
--    Réservé au valideur de la demande ou à un administrateur ; motif obligatoire
-- ---------------------------------------------------------------------
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

  n := public.count_leave_days(p_start, p_end, p_start_half, p_end_half, emp.work_country);
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
