-- =====================================================================
-- 法籍员工休假审批平台 / Plateforme de gestion des congés des expatriés
-- 001 — 表结构、权限、业务函数 / Schéma, droits, fonctions métier
-- 在 Supabase → SQL Editor 中整段运行一次。
-- À exécuter une seule fois dans Supabase → SQL Editor.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. 全局设置 / Paramètres
-- count_mode:
--   ouvrables  = 周一至周六，扣除法定假日（几内亚《劳动法》口径）
--                du lundi au samedi, hors jours fériés
--   ouvres     = 周一至周五，扣除法定假日 / du lundi au vendredi, hors fériés
--   calendaires= 自然日 / jours calendaires
-- ---------------------------------------------------------------------
create table public.app_settings (
  id                   int primary key default 1 check (id = 1),
  count_mode           text not null default 'ouvrables'
                         check (count_mode in ('ouvrables','ouvres','calendaires')),
  default_annual_days  numeric(5,1) not null default 30,
  company_name         text not null default 'Winning Consortium',
  updated_at           timestamptz not null default now()
);
insert into public.app_settings (id) values (1);

-- ---------------------------------------------------------------------
-- 2. 用户档案 / Profils
-- role: employee 员工 / approver 审批人 / admin 管理员
-- ---------------------------------------------------------------------
create table public.profiles (
  id                    uuid primary key references auth.users(id) on delete cascade,
  email                 text not null,
  full_name             text not null default '',
  employee_no           text,
  position              text,
  department            text,
  site                  text,
  role                  text not null default 'employee'
                          check (role in ('employee','approver','admin')),
  approver_id           uuid references public.profiles(id) on delete set null,
  hire_date             date,
  active                boolean not null default true,
  must_change_password  boolean not null default true,
  lang                  text not null default 'fr' check (lang in ('zh','fr')),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  constraint approver_not_self check (approver_id is null or approver_id <> id)
);
create index profiles_approver_idx on public.profiles(approver_id);

-- ---------------------------------------------------------------------
-- 3. 假期类型 / Types de congé
-- ---------------------------------------------------------------------
create table public.leave_types (
  code                 text primary key,
  name_zh              text not null,
  name_fr              text not null,
  deducts_balance      boolean not null default false,  -- 是否扣年假余额 / décompté du solde
  requires_attachment  boolean not null default false,  -- 是否必须上传附件 / justificatif obligatoire
  color                text not null default '#64748b',
  active               boolean not null default true,
  sort_order           int not null default 0
);

-- ---------------------------------------------------------------------
-- 4. 法定假日 / Jours fériés
-- ---------------------------------------------------------------------
create table public.holidays (
  day      date primary key,
  name_zh  text not null,
  name_fr  text not null
);

-- ---------------------------------------------------------------------
-- 5. 年假额度 / Droits annuels
-- 未设置的年份自动使用 app_settings.default_annual_days
-- ---------------------------------------------------------------------
create table public.leave_entitlements (
  user_id       uuid not null references public.profiles(id) on delete cascade,
  year          int  not null check (year between 2000 and 2100),
  annual_days   numeric(5,1) not null check (annual_days >= 0),
  carried_over  numeric(5,1) not null default 0,   -- 上年结转 / report N-1
  adjustment    numeric(5,1) not null default 0,   -- 手工调整 / ajustement
  note          text,
  updated_at    timestamptz not null default now(),
  primary key (user_id, year)
);

-- ---------------------------------------------------------------------
-- 6. 休假申请 / Demandes de congé
-- start_half = 首日下午开始 / commence l'après-midi
-- end_half   = 末日上午结束 / se termine à midi
-- ---------------------------------------------------------------------
create sequence public.leave_ref_seq;

create table public.leave_requests (
  id                uuid primary key default gen_random_uuid(),
  ref_no            text unique,
  user_id           uuid not null references public.profiles(id) on delete cascade,
  type_code         text not null references public.leave_types(code),
  start_date        date not null,
  end_date          date not null,
  start_half        boolean not null default false,
  end_half          boolean not null default false,
  days              numeric(5,1) not null check (days > 0),
  reason            text,
  destination       text,
  contact           text,
  attachment_path   text,
  status            text not null default 'pending'
                      check (status in ('pending','approved','rejected','cancelled')),
  approver_id       uuid references public.profiles(id) on delete set null,
  decided_by        uuid references public.profiles(id) on delete set null,
  decided_by_name   text,
  decided_at        timestamptz,
  decision_comment  text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint dates_order check (end_date >= start_date)
);
create index leave_requests_user_idx     on public.leave_requests(user_id, start_date desc);
create index leave_requests_approver_idx on public.leave_requests(approver_id, status);
create index leave_requests_status_idx   on public.leave_requests(status, start_date);

-- 操作记录 / Historique
create table public.leave_events (
  id          bigint generated always as identity primary key,
  request_id  uuid not null references public.leave_requests(id) on delete cascade,
  actor_id    uuid references public.profiles(id) on delete set null,
  actor_name  text,
  action      text not null check (action in ('submitted','approved','rejected','cancelled')),
  comment     text,
  created_at  timestamptz not null default now()
);
create index leave_events_request_idx on public.leave_events(request_id);

-- ---------------------------------------------------------------------
-- 7. 通用触发器 / Déclencheurs
-- ---------------------------------------------------------------------
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create trigger trg_profiles_touch     before update on public.profiles
  for each row execute function public.touch_updated_at();
create trigger trg_requests_touch     before update on public.leave_requests
  for each row execute function public.touch_updated_at();
create trigger trg_entitlements_touch before update on public.leave_entitlements
  for each row execute function public.touch_updated_at();
create trigger trg_settings_touch     before update on public.app_settings
  for each row execute function public.touch_updated_at();

-- 新建 auth 用户时自动建档；系统中第一个用户自动成为管理员
-- Création automatique du profil ; le tout premier utilisateur devient administrateur
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare is_first boolean;
begin
  select not exists (select 1 from public.profiles) into is_first;
  insert into public.profiles (id, email, full_name, lang, role, must_change_password)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    case when new.raw_user_meta_data->>'lang' in ('zh','fr')
         then new.raw_user_meta_data->>'lang' else 'fr' end,
    case when is_first then 'admin' else 'employee' end,
    not is_first
  )
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- 8. 权限辅助函数 / Fonctions d'autorisation
-- ---------------------------------------------------------------------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = auth.uid() and role = 'admin' and active);
$$;

create or replace function public.my_approver_id() returns uuid
language sql stable security definer set search_path = public as $$
  select approver_id from public.profiles where id = auth.uid();
$$;

create or replace function public.is_approver_of(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles
                 where id = p_user and approver_id = auth.uid());
$$;

-- ---------------------------------------------------------------------
-- 9. 天数计算 / Calcul du nombre de jours
-- ---------------------------------------------------------------------
create or replace function public.count_leave_days(
  p_start date, p_end date,
  p_start_half boolean default false, p_end_half boolean default false
) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare
  v_mode text;
  d date;
  n numeric := 0;
  counted boolean;
begin
  if p_start is null or p_end is null or p_end < p_start then return 0; end if;
  if p_end - p_start > 366 then return 0; end if;
  select count_mode into v_mode from public.app_settings where id = 1;

  for d in select g::date from generate_series(p_start, p_end, interval '1 day') g loop
    counted := case v_mode
      when 'calendaires' then true
      when 'ouvres'      then extract(isodow from d) < 6
                              and not exists (select 1 from public.holidays h where h.day = d)
      else                    extract(isodow from d) < 7
                              and not exists (select 1 from public.holidays h where h.day = d)
    end;
    if counted then
      if (d = p_start and p_start_half) or (d = p_end and p_end_half) then
        n := n + 0.5;
      else
        n := n + 1;
      end if;
    end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- 10. 年假余额 / Solde de congés
-- ---------------------------------------------------------------------
create or replace function public._leave_balance(p_user uuid, p_year int)
returns table (year int, entitled numeric, carried_over numeric, adjustment numeric,
               total numeric, used numeric, pending numeric, available numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  e_days numeric; e_carry numeric := 0; e_adj numeric := 0;
  v_used numeric; v_pend numeric;
begin
  select le.annual_days, le.carried_over, le.adjustment
    into e_days, e_carry, e_adj
    from public.leave_entitlements le
   where le.user_id = p_user and le.year = p_year;
  if e_days is null then
    select s.default_annual_days into e_days from public.app_settings s where s.id = 1;
    e_carry := 0; e_adj := 0;
  end if;

  select coalesce(sum(r.days) filter (where r.status = 'approved'), 0),
         coalesce(sum(r.days) filter (where r.status = 'pending'), 0)
    into v_used, v_pend
    from public.leave_requests r
    join public.leave_types t on t.code = r.type_code and t.deducts_balance
   where r.user_id = p_user
     and extract(year from r.start_date)::int = p_year;

  year := p_year; entitled := e_days; carried_over := e_carry; adjustment := e_adj;
  total := e_days + e_carry + e_adj;
  used := v_used; pending := v_pend;
  available := total - v_used - v_pend;
  return next;
end $$;

create or replace function public.leave_balance(p_user uuid default null, p_year int default null)
returns table (year int, entitled numeric, carried_over numeric, adjustment numeric,
               total numeric, used numeric, pending numeric, available numeric)
language plpgsql stable security definer set search_path = public as $$
declare u uuid := coalesce(p_user, auth.uid());
begin
  if not (u = auth.uid() or public.is_admin() or public.is_approver_of(u)) then
    raise exception 'ERR_FORBIDDEN';
  end if;
  return query select * from public._leave_balance(
    u, coalesce(p_year, extract(year from current_date)::int));
end $$;

-- 管理员一次取全员余额 / Soldes de tous (admin)
create or replace function public.all_balances(p_year int default null)
returns table (user_id uuid, year int, entitled numeric, carried_over numeric,
               adjustment numeric, total numeric, used numeric, pending numeric, available numeric)
language plpgsql stable security definer set search_path = public as $$
declare y int := coalesce(p_year, extract(year from current_date)::int);
begin
  if not public.is_admin() then raise exception 'ERR_FORBIDDEN'; end if;
  return query
    select p.id, b.* from public.profiles p
    cross join lateral public._leave_balance(p.id, y) b
    order by p.full_name;
end $$;

-- ---------------------------------------------------------------------
-- 11. 提交申请 / Soumettre une demande
-- 错误以 ERR_xxx 代码抛出，前端按语言翻译
-- Les erreurs sont renvoyées sous forme de codes ERR_xxx traduits côté client
-- ---------------------------------------------------------------------
create or replace function public.submit_leave(
  p_type text, p_start date, p_end date,
  p_start_half boolean default false, p_end_half boolean default false,
  p_reason text default null, p_destination text default null,
  p_contact text default null, p_attachment text default null
) returns public.leave_requests
language plpgsql security definer set search_path = public as $$
declare
  me   public.profiles;
  lt   public.leave_types;
  n    numeric;
  bal  record;
  r    public.leave_requests;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.active then raise exception 'ERR_ACCOUNT_INACTIVE'; end if;

  select * into lt from public.leave_types where code = p_type and active;
  if lt.code is null then raise exception 'ERR_TYPE'; end if;

  if p_start is null or p_end is null or p_end < p_start then raise exception 'ERR_DATES'; end if;
  if p_start = p_end and p_start_half and p_end_half then raise exception 'ERR_HALF'; end if;
  if p_start < current_date - 60 then raise exception 'ERR_TOO_OLD'; end if;
  if lt.deducts_balance and extract(year from p_start) <> extract(year from p_end) then
    raise exception 'ERR_CROSS_YEAR';
  end if;

  n := public.count_leave_days(p_start, p_end, p_start_half, p_end_half);
  if n <= 0 then raise exception 'ERR_ZERO_DAYS'; end if;

  if exists (select 1 from public.leave_requests x
              where x.user_id = me.id and x.status in ('pending','approved')
                and daterange(x.start_date, x.end_date, '[]')
                 && daterange(p_start, p_end, '[]')) then
    raise exception 'ERR_OVERLAP';
  end if;

  if p_attachment is not null and p_attachment <> '' then
    if split_part(p_attachment, '/', 1) <> me.id::text then raise exception 'ERR_ATTACHMENT'; end if;
  elsif lt.requires_attachment then
    raise exception 'ERR_ATTACHMENT_REQUIRED';
  end if;

  if lt.deducts_balance then
    select * into bal from public._leave_balance(me.id, extract(year from p_start)::int);
    if n > bal.available then
      raise exception 'ERR_BALANCE' using detail = bal.available::text;
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

-- ---------------------------------------------------------------------
-- 12. 审批 / Décision
-- ---------------------------------------------------------------------
create or replace function public.decide_leave(p_id uuid, p_decision text, p_comment text default null)
returns public.leave_requests
language plpgsql security definer set search_path = public as $$
declare
  me  public.profiles;
  r   public.leave_requests;
  lt  public.leave_types;
  bal record;
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
    if lt.deducts_balance then
      select * into bal from public._leave_balance(r.user_id, extract(year from r.start_date)::int);
      -- 本申请已计入 pending，因此只需校验 total - used
      if r.days > bal.total - bal.used then
        raise exception 'ERR_BALANCE' using detail = (bal.total - bal.used)::text;
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

-- ---------------------------------------------------------------------
-- 13. 撤回 / Annulation
-- 员工可撤回自己"待审批"的申请；管理员可撤销待审批或已批准的申请
-- L'employé annule ses demandes en attente ; l'admin peut annuler une demande approuvée
-- ---------------------------------------------------------------------
create or replace function public.cancel_leave(p_id uuid, p_comment text default null)
returns public.leave_requests
language plpgsql security definer set search_path = public as $$
declare
  me public.profiles;
  r  public.leave_requests;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.active then raise exception 'ERR_ACCOUNT_INACTIVE'; end if;

  select * into r from public.leave_requests where id = p_id for update;
  if r.id is null then raise exception 'ERR_NOT_FOUND'; end if;

  if me.role = 'admin' then
    if r.status not in ('pending','approved') then raise exception 'ERR_NOT_CANCELLABLE'; end if;
  elsif r.user_id = me.id then
    if r.status <> 'pending' then raise exception 'ERR_NOT_CANCELLABLE'; end if;
  else
    raise exception 'ERR_FORBIDDEN';
  end if;

  update public.leave_requests
     set status = 'cancelled',
         decided_by = me.id, decided_by_name = me.full_name, decided_at = now(),
         decision_comment = coalesce(nullif(trim(p_comment), ''), decision_comment)
   where id = p_id
  returning * into r;

  insert into public.leave_events (request_id, actor_id, actor_name, action, comment)
  values (r.id, me.id, me.full_name, 'cancelled', nullif(trim(p_comment), ''));
  return r;
end $$;

-- ---------------------------------------------------------------------
-- 14. 个人设置 / Préférences personnelles
-- ---------------------------------------------------------------------
create or replace function public.set_my_lang(p_lang text) returns void
language sql security definer set search_path = public as $$
  update public.profiles set lang = p_lang
   where id = auth.uid() and p_lang in ('zh','fr');
$$;

create or replace function public.mark_password_changed() returns void
language sql security definer set search_path = public as $$
  update public.profiles set must_change_password = false where id = auth.uid();
$$;

-- 员工查看审批人姓名 / Nom du valideur
create or replace function public.my_context()
returns table (approver_name text, approver_email text)
language sql stable security definer set search_path = public as $$
  select a.full_name, a.email
    from public.profiles me
    left join public.profiles a on a.id = me.approver_id
   where me.id = auth.uid();
$$;

-- ---------------------------------------------------------------------
-- 15. 行级安全 / Row Level Security
-- ---------------------------------------------------------------------
alter table public.app_settings       enable row level security;
alter table public.profiles           enable row level security;
alter table public.leave_types        enable row level security;
alter table public.holidays           enable row level security;
alter table public.leave_entitlements enable row level security;
alter table public.leave_requests     enable row level security;
alter table public.leave_events       enable row level security;

-- 设置、假期类型、假日：登录用户可读，管理员可写
create policy settings_read  on public.app_settings for select to authenticated using (true);
create policy settings_admin on public.app_settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy types_read  on public.leave_types for select to authenticated using (true);
create policy types_admin on public.leave_types for all    to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy holidays_read  on public.holidays for select to authenticated using (true);
create policy holidays_admin on public.holidays for all    to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- 档案：本人、本人的审批人、下属（对审批人而言）、管理员
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or approver_id = auth.uid()
         or id = public.my_approver_id() or public.is_admin());
create policy profiles_admin_update on public.profiles for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- 额度
create policy ent_read on public.leave_entitlements for select to authenticated
  using (user_id = auth.uid() or public.is_approver_of(user_id) or public.is_admin());
create policy ent_admin on public.leave_entitlements for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- 申请：只读；写入全部通过上面的函数
create policy requests_read on public.leave_requests for select to authenticated
  using (user_id = auth.uid() or approver_id = auth.uid() or public.is_admin());

create policy events_read on public.leave_events for select to authenticated
  using (exists (select 1 from public.leave_requests r where r.id = request_id));

-- ---------------------------------------------------------------------
-- 16. 函数执行权限 / Droits d'exécution
-- ---------------------------------------------------------------------
revoke execute on function public._leave_balance(uuid, int)           from public, anon, authenticated;
revoke execute on function public.handle_new_user()                    from public, anon, authenticated;
revoke execute on function public.leave_balance(uuid, int)             from public, anon;
revoke execute on function public.all_balances(int)                    from public, anon;
revoke execute on function public.submit_leave(text,date,date,boolean,boolean,text,text,text,text) from public, anon;
revoke execute on function public.decide_leave(uuid, text, text)       from public, anon;
revoke execute on function public.cancel_leave(uuid, text)             from public, anon;
revoke execute on function public.set_my_lang(text)                    from public, anon;
revoke execute on function public.mark_password_changed()              from public, anon;
revoke execute on function public.my_context()                         from public, anon;
revoke execute on function public.count_leave_days(date,date,boolean,boolean) from public, anon;

grant execute on function public.leave_balance(uuid, int)             to authenticated;
grant execute on function public.all_balances(int)                    to authenticated;
grant execute on function public.submit_leave(text,date,date,boolean,boolean,text,text,text,text) to authenticated;
grant execute on function public.decide_leave(uuid, text, text)       to authenticated;
grant execute on function public.cancel_leave(uuid, text)             to authenticated;
grant execute on function public.set_my_lang(text)                    to authenticated;
grant execute on function public.mark_password_changed()              to authenticated;
grant execute on function public.my_context()                         to authenticated;
grant execute on function public.count_leave_days(date,date,boolean,boolean) to authenticated;

-- ---------------------------------------------------------------------
-- 17. 初始数据 / Données initiales
-- ---------------------------------------------------------------------
insert into public.leave_types (code, name_zh, name_fr, deducts_balance, color, sort_order) values
  ('annual',      '年假',          'Congé annuel',                      true,  '#2563eb', 1),
  ('home',        '回国探亲假',     'Congé de détente (retour au pays)', false, '#0891b2', 2),
  ('sick',        '病假',          'Congé maladie',                     false, '#dc2626', 3),
  ('family',      '婚丧等特殊事假', 'Congé pour événement familial',      false, '#7c3aed', 4),
  ('maternity',   '产假 / 陪产假',  'Congé maternité / paternité',        false, '#db2777', 5),
  ('unpaid',      '无薪事假',       'Congé sans solde',                  false, '#64748b', 6),
  ('recovery',    '调休',          'Récupération',                      false, '#16a34a', 7);

-- 固定日期的几内亚法定假日。伊斯兰节日（开斋节、宰牲节、圣纪节等）每年由政府公布日期，请管理员在后台补充。
-- Jours fériés à date fixe. Les fêtes musulmanes (Aïd el-Fitr, Tabaski, Maouloud…) sont fixées
-- chaque année par décret : l'administrateur doit les ajouter dans l'interface.
insert into public.holidays (day, name_zh, name_fr) values
  ('2026-01-01','元旦','Jour de l''An'),
  ('2026-04-06','复活节星期一','Lundi de Pâques'),
  ('2026-05-01','劳动节','Fête du Travail'),
  ('2026-05-25','非洲日','Journée de l''Afrique'),
  ('2026-08-15','圣母升天节','Assomption'),
  ('2026-10-02','独立日','Fête de l''Indépendance'),
  ('2026-11-01','诸圣节','Toussaint'),
  ('2026-12-25','圣诞节','Noël'),
  ('2027-01-01','元旦','Jour de l''An'),
  ('2027-03-29','复活节星期一','Lundi de Pâques'),
  ('2027-05-01','劳动节','Fête du Travail'),
  ('2027-05-25','非洲日','Journée de l''Afrique'),
  ('2027-08-15','圣母升天节','Assomption'),
  ('2027-10-02','独立日','Fête de l''Indépendance'),
  ('2027-11-01','诸圣节','Toussaint'),
  ('2027-12-25','圣诞节','Noël');
