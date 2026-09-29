-- =====================================================================
-- 003 — 升级 / Mise à jour
--  · 每人单独设置年假、病假天数（设置一次，适用于所有年份）
--    Droits annuels et maladie définis par salarié, valables pour toutes les années
--  · 入职当年按剩余天数自动折算 / Proratisation l'année d'entrée
--  · 试用期截止日期：试用期结束前不能请年假 / Pas de congé annuel pendant la période d'essai
--  · 工作国家、国籍（国家列表可维护）/ Pays d'affectation et nationalité
--  · 法定假日按工作国家区分 / Jours fériés par pays
--  · 系统起始年份 2026 / Année de démarrage 2026
-- 在 SQL Editor 中整段运行一次 / À exécuter une fois dans le SQL Editor
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. 国家 / Pays
-- ---------------------------------------------------------------------
create table if not exists public.countries (
  code             text primary key check (code ~ '^[A-Z]{2}$'),
  name_zh          text not null,
  name_fr          text not null,
  is_work_country  boolean not null default false,   -- 出现在"工作国家"下拉 / proposé comme pays d'affectation
  sort_order       int not null default 100
);
insert into public.countries (code, name_zh, name_fr, is_work_country, sort_order) values
  ('CN','中国','Chine',true,1), ('GN','几内亚','Guinée',true,2),
  ('CI','科特迪瓦','Côte d''Ivoire',true,3), ('SG','新加坡','Singapour',true,4),
  ('FR','法国','France',false,10), ('BE','比利时','Belgique',false,11), ('CH','瑞士','Suisse',false,12),
  ('CA','加拿大','Canada',false,13), ('LU','卢森堡','Luxembourg',false,14), ('MC','摩纳哥','Monaco',false,15),
  ('SN','塞内加尔','Sénégal',false,20), ('ML','马里','Mali',false,21), ('MA','摩洛哥','Maroc',false,22),
  ('TN','突尼斯','Tunisie',false,23), ('DZ','阿尔及利亚','Algérie',false,24), ('CM','喀麦隆','Cameroun',false,25),
  ('SL','塞拉利昂','Sierra Leone',false,26), ('LR','利比里亚','Liberia',false,27), ('GH','加纳','Ghana',false,28),
  ('GB','英国','Royaume-Uni',false,40), ('DE','德国','Allemagne',false,41), ('ES','西班牙','Espagne',false,42),
  ('IT','意大利','Italie',false,43), ('PT','葡萄牙','Portugal',false,44), ('US','美国','États-Unis',false,45),
  ('AU','澳大利亚','Australie',false,46)
on conflict (code) do nothing;

alter table public.countries enable row level security;
drop policy if exists countries_read  on public.countries;
drop policy if exists countries_admin on public.countries;
create policy countries_read  on public.countries for select to authenticated using (true);
create policy countries_admin on public.countries for all    to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------
-- 2. 全局设置 / Paramètres
-- ---------------------------------------------------------------------
alter table public.app_settings
  add column if not exists default_sick_days numeric(5,1) not null default 15,
  add column if not exists first_year        int          not null default 2026;

-- ---------------------------------------------------------------------
-- 3. 用户档案 / Profils
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists annual_days    numeric(5,1) check (annual_days >= 0),
  add column if not exists sick_days      numeric(5,1) check (sick_days >= 0),
  add column if not exists probation_end  date,
  add column if not exists work_country   text references public.countries(code) default 'GN',
  add column if not exists nationality    text references public.countries(code);
update public.profiles set work_country = 'GN' where work_country is null;

-- 原先按年设置的年假天数 → 转为个人年假天数（取最近一年）
-- Reprise des droits annuels saisis auparavant par année
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='leave_entitlements' and column_name='annual_days') then
    execute 'update public.profiles p set annual_days = e.annual_days
               from (select distinct on (user_id) user_id, annual_days
                       from public.leave_entitlements order by user_id, year desc) e
              where e.user_id = p.id and p.annual_days is null';
  end if;
end $$;

alter table public.profiles drop column if exists site;

-- ---------------------------------------------------------------------
-- 4. 年度结转 / 调整（按假期额度种类）/ Report et ajustement par année et par solde
-- ---------------------------------------------------------------------
alter table public.leave_entitlements drop constraint if exists leave_entitlements_pkey;
alter table public.leave_entitlements
  add column if not exists kind text not null default 'annual' check (kind in ('annual','sick'));
alter table public.leave_entitlements drop column if exists annual_days;
alter table public.leave_entitlements add primary key (user_id, year, kind);

-- ---------------------------------------------------------------------
-- 5. 假期类型：扣减哪个额度 / Solde auquel le type est imputé
-- ---------------------------------------------------------------------
alter table public.leave_types
  add column if not exists balance_kind text check (balance_kind in ('annual','sick'));
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='leave_types' and column_name='deducts_balance') then
    execute 'update public.leave_types set balance_kind = ''annual'' where deducts_balance';
  end if;
end $$;
update public.leave_types set balance_kind = 'sick' where code = 'sick' and balance_kind is null;
alter table public.leave_types drop column if exists deducts_balance;

-- ---------------------------------------------------------------------
-- 6. 法定假日按国家 / Jours fériés par pays
-- ---------------------------------------------------------------------
alter table public.holidays
  add column if not exists country_code text not null default 'GN' references public.countries(code);
alter table public.holidays drop constraint if exists holidays_pkey;
alter table public.holidays add primary key (day, country_code);

-- ---------------------------------------------------------------------
-- 7. 函数 / Fonctions
-- ---------------------------------------------------------------------
drop function if exists public.count_leave_days(date, date, boolean, boolean);
drop function if exists public.leave_balance(uuid, int);
drop function if exists public.all_balances(int);
drop function if exists public._leave_balance(uuid, int);

-- 天数计算（按员工工作国家的法定假日）/ Décompte selon les fériés du pays d'affectation
create or replace function public.count_leave_days(
  p_start date, p_end date,
  p_start_half boolean default false, p_end_half boolean default false,
  p_country text default null
) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare
  v_mode text; v_country text; d date; n numeric := 0; counted boolean;
begin
  if p_start is null or p_end is null or p_end < p_start then return 0; end if;
  if p_end - p_start > 366 then return 0; end if;
  select s.count_mode into v_mode from public.app_settings s where s.id = 1;
  v_country := coalesce(p_country,
                        (select pr.work_country from public.profiles pr where pr.id = auth.uid()),
                        'GN');
  for d in select g::date from generate_series(p_start, p_end, interval '1 day') g loop
    counted := case v_mode
      when 'calendaires' then true
      when 'ouvres' then extract(isodow from d) < 6
        and not exists (select 1 from public.holidays h where h.day = d and h.country_code = v_country)
      else extract(isodow from d) < 7
        and not exists (select 1 from public.holidays h where h.day = d and h.country_code = v_country)
    end;
    if counted then
      n := n + case when (d = p_start and p_start_half) or (d = p_end and p_end_half) then 0.5 else 1 end;
    end if;
  end loop;
  return n;
end $$;

-- 额度与余额（含入职折算）/ Droits et solde (avec proratisation)
create or replace function public._leave_balance(p_user uuid, p_year int, p_kind text)
returns table (kind text, year int, base numeric, entitled numeric, prorated boolean,
               carried_over numeric, adjustment numeric, total numeric,
               used numeric, pending numeric, available numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  pr public.profiles; st public.app_settings;
  y0 date := make_date(p_year, 1, 1); y1 date := make_date(p_year, 12, 31);
  v_base numeric; v_ent numeric; v_pr boolean := false;
  v_carry numeric := 0; v_adj numeric := 0; v_used numeric; v_pend numeric;
begin
  select * into pr from public.profiles where id = p_user;
  select * into st from public.app_settings where id = 1;
  v_base := case p_kind when 'sick' then coalesce(pr.sick_days, st.default_sick_days)
                        else coalesce(pr.annual_days, st.default_annual_days) end;

  if pr.hire_date is null or pr.hire_date <= y0 then
    v_ent := v_base;
  elsif pr.hire_date > y1 then
    v_ent := 0; v_pr := true;
  else
    -- 按当年剩余自然日比例折算，四舍五入到 0.5 天
    -- Au prorata des jours restants dans l'année, arrondi à la demi-journée
    v_ent := (round(v_base * (y1 - pr.hire_date + 1)::numeric / (y1 - y0 + 1) * 2) / 2)::numeric(6,1);
    v_pr := true;
  end if;

  select coalesce(e.carried_over, 0), coalesce(e.adjustment, 0) into v_carry, v_adj
    from public.leave_entitlements e
   where e.user_id = p_user and e.year = p_year and e.kind = p_kind;
  v_carry := coalesce(v_carry, 0); v_adj := coalesce(v_adj, 0);

  select coalesce(sum(r.days) filter (where r.status = 'approved'), 0),
         coalesce(sum(r.days) filter (where r.status = 'pending'), 0)
    into v_used, v_pend
    from public.leave_requests r
    join public.leave_types t on t.code = r.type_code and t.balance_kind = p_kind
   where r.user_id = p_user and extract(year from r.start_date)::int = p_year;

  kind := p_kind; year := p_year; base := v_base; entitled := v_ent; prorated := v_pr;
  carried_over := v_carry; adjustment := v_adj; total := v_ent + v_carry + v_adj;
  used := v_used; pending := v_pend; available := total - v_used - v_pend;
  return next;
end $$;

create or replace function public.leave_balance(p_user uuid default null, p_year int default null)
returns table (kind text, year int, base numeric, entitled numeric, prorated boolean,
               carried_over numeric, adjustment numeric, total numeric,
               used numeric, pending numeric, available numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  u uuid := coalesce(p_user, auth.uid());
  y int := coalesce(p_year, extract(year from current_date)::int);
begin
  if not (u = auth.uid() or public.is_admin() or public.is_approver_of(u)) then
    raise exception 'ERR_FORBIDDEN';
  end if;
  return query
    select * from public._leave_balance(u, y, 'annual')
    union all
    select * from public._leave_balance(u, y, 'sick');
end $$;

create or replace function public.all_balances(p_year int default null)
returns table (user_id uuid, kind text, year int, base numeric, entitled numeric, prorated boolean,
               carried_over numeric, adjustment numeric, total numeric,
               used numeric, pending numeric, available numeric)
language plpgsql stable security definer set search_path = public as $$
declare y int := coalesce(p_year, extract(year from current_date)::int);
begin
  if not public.is_admin() then raise exception 'ERR_FORBIDDEN'; end if;
  return query
    select p.id, b.* from public.profiles p
    cross join lateral (
      select * from public._leave_balance(p.id, y, 'annual')
      union all
      select * from public._leave_balance(p.id, y, 'sick')) b
    order by p.full_name, b.kind;
end $$;

-- 提交申请 / Soumettre
create or replace function public.submit_leave(
  p_type text, p_start date, p_end date,
  p_start_half boolean default false, p_end_half boolean default false,
  p_reason text default null, p_destination text default null,
  p_contact text default null, p_attachment text default null
) returns public.leave_requests
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles; lt public.leave_types; st public.app_settings;
  n numeric; bal record; r public.leave_requests;
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

  -- 试用期内不能请年假 / Pas de congé annuel pendant la période d'essai
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

  if p_attachment is not null and p_attachment <> '' then
    if split_part(p_attachment, '/', 1) <> me.id::text then raise exception 'ERR_ATTACHMENT'; end if;
  elsif lt.requires_attachment then
    raise exception 'ERR_ATTACHMENT_REQUIRED';
  end if;

  if lt.balance_kind is not null then
    select * into bal from public._leave_balance(me.id, extract(year from p_start)::int, lt.balance_kind);
    if n > bal.available then
      raise exception 'ERR_BALANCE' using detail = bal.available::text, hint = lt.balance_kind;
    end if;
  end if;

  insert into public.leave_requests
    (ref_no, user_id, type_code, start_date, end_date, start_half, end_half, days,
     reason, destination, contact, attachment_path, approver_id)
  values
    ('CG-' || extract(year from current_date)::int || '-' || lpad(nextval('public.leave_ref_seq')::text, 4, '0'),
     me.id, p_type, p_start, p_end, p_start_half, p_end_half, n,
     nullif(trim(p_reason), ''), nullif(trim(p_destination), ''), nullif(trim(p_contact), ''),
     nullif(p_attachment, ''), me.approver_id)
  returning * into r;

  insert into public.leave_events (request_id, actor_id, actor_name, action)
  values (r.id, me.id, me.full_name, 'submitted');
  return r;
end $$;

-- 审批 / Décision
create or replace function public.decide_leave(p_id uuid, p_decision text, p_comment text default null)
returns public.leave_requests
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles; r public.leave_requests; lt public.leave_types; bal record;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.active then raise exception 'ERR_ACCOUNT_INACTIVE'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'ERR_DECISION'; end if;

  select * into r from public.leave_requests where id = p_id for update;
  if r.id is null then raise exception 'ERR_NOT_FOUND'; end if;
  if r.user_id = me.id then raise exception 'ERR_SELF_APPROVAL'; end if;
  if not (r.approver_id = me.id or me.role = 'admin') then raise exception 'ERR_FORBIDDEN'; end if;
  if r.status <> 'pending' then raise exception 'ERR_NOT_PENDING'; end if;
  if p_decision = 'rejected' and coalesce(trim(p_comment), '') = '' then
    raise exception 'ERR_COMMENT_REQUIRED';
  end if;

  if p_decision = 'approved' then
    select * into lt from public.leave_types where code = r.type_code;
    if lt.balance_kind is not null then
      select * into bal from public._leave_balance(r.user_id, extract(year from r.start_date)::int, lt.balance_kind);
      if r.days > bal.total - bal.used then
        raise exception 'ERR_BALANCE' using detail = (bal.total - bal.used)::text, hint = lt.balance_kind;
      end if;
    end if;
  end if;

  update public.leave_requests
     set status = p_decision, decided_by = me.id, decided_by_name = me.full_name,
         decided_at = now(), decision_comment = nullif(trim(p_comment), '')
   where id = p_id
  returning * into r;

  insert into public.leave_events (request_id, actor_id, actor_name, action, comment)
  values (r.id, me.id, me.full_name, p_decision, nullif(trim(p_comment), ''));
  return r;
end $$;

-- 权限 / Droits
revoke execute on function public._leave_balance(uuid, int, text) from public, anon, authenticated;
revoke execute on function public.leave_balance(uuid, int)        from public, anon;
revoke execute on function public.all_balances(int)               from public, anon;
revoke execute on function public.count_leave_days(date,date,boolean,boolean,text) from public, anon;
grant  execute on function public.leave_balance(uuid, int)        to authenticated;
grant  execute on function public.all_balances(int)               to authenticated;
grant  execute on function public.count_leave_days(date,date,boolean,boolean,text) to authenticated;

commit;
