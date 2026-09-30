-- =====================================================================
-- 008 — 1) 修改年假/病假天数不影响以往年份
--          Modifier les droits annuels n'affecte pas les années passées
--       2) 已批准的申请不能撤回 / Une demande approuvée ne peut plus être annulée
-- 可重复运行 / ré-exécutable
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. 每年的额度快照 / Droits figés par année
--    base_days 为空 = 使用员工当前设置（今年及以后）
--    base_days vide = valeur actuelle du salarié (année en cours et suivantes)
-- ---------------------------------------------------------------------
alter table public.leave_entitlements add column if not exists base_days numeric(5,1);
alter table public.leave_entitlements drop constraint if exists leave_entitlements_base_days_check;
alter table public.leave_entitlements add constraint leave_entitlements_base_days_check check (base_days is null or base_days >= 0);

-- 把"旧值"写入以往各年（已有快照的年份不动）
-- Fige l'ancienne valeur pour les années passées sans valeur figée
create or replace function public._freeze_past_entitlement(p_user uuid, p_kind text, p_old numeric)
returns void language plpgsql security definer set search_path = public as $$
declare
  st public.app_settings; pr public.profiles; y int; y_from int;
  y_now int := extract(year from current_date)::int;
begin
  select * into st from public.app_settings where id = 1;
  select * into pr from public.profiles where id = p_user;
  y_from := greatest(st.first_year, coalesce(extract(year from pr.hire_date)::int, st.first_year));
  for y in y_from .. y_now - 1 loop
    insert into public.leave_entitlements (user_id, year, kind, base_days)
    values (p_user, y, p_kind, p_old)
    on conflict (user_id, year, kind) do update
      set base_days = coalesce(public.leave_entitlements.base_days, excluded.base_days);
  end loop;
end $$;

-- 员工天数被修改时 / À la modification des droits d'un salarié
create or replace function public.trg_profiles_freeze_days() returns trigger
language plpgsql security definer set search_path = public as $$
declare st public.app_settings;
begin
  select * into st from public.app_settings where id = 1;
  if coalesce(new.annual_days, st.default_annual_days) is distinct from coalesce(old.annual_days, st.default_annual_days) then
    perform public._freeze_past_entitlement(old.id, 'annual', coalesce(old.annual_days, st.default_annual_days));
  end if;
  if coalesce(new.sick_days, st.default_sick_days) is distinct from coalesce(old.sick_days, st.default_sick_days) then
    perform public._freeze_past_entitlement(old.id, 'sick', coalesce(old.sick_days, st.default_sick_days));
  end if;
  return new;
end $$;

drop trigger if exists trg_profiles_freeze_days on public.profiles;
create trigger trg_profiles_freeze_days
  before update of annual_days, sick_days on public.profiles
  for each row execute function public.trg_profiles_freeze_days();

-- 默认天数被修改时：对使用默认值的员工同样处理
-- À la modification des valeurs par défaut : idem pour les salariés sans valeur propre
create or replace function public.trg_settings_freeze_days() returns trigger
language plpgsql security definer set search_path = public as $$
declare p record;
begin
  if new.default_annual_days is distinct from old.default_annual_days then
    for p in select id from public.profiles where annual_days is null loop
      perform public._freeze_past_entitlement(p.id, 'annual', old.default_annual_days);
    end loop;
  end if;
  if new.default_sick_days is distinct from old.default_sick_days then
    for p in select id from public.profiles where sick_days is null loop
      perform public._freeze_past_entitlement(p.id, 'sick', old.default_sick_days);
    end loop;
  end if;
  return new;
end $$;

drop trigger if exists trg_settings_freeze_days on public.app_settings;
create trigger trg_settings_freeze_days
  before update of default_annual_days, default_sick_days on public.app_settings
  for each row execute function public.trg_settings_freeze_days();

revoke execute on function public._freeze_past_entitlement(uuid, text, numeric) from public, anon, authenticated;

-- 余额：优先使用该年快照 / Solde : valeur figée de l'année en priorité
create or replace function public._leave_balance(p_user uuid, p_year int, p_kind text)
returns table (kind text, year int, base numeric, entitled numeric, prorated boolean,
               carried_over numeric, adjustment numeric, total numeric,
               used numeric, pending numeric, available numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  pr public.profiles; st public.app_settings; e public.leave_entitlements;
  y0 date := make_date(p_year, 1, 1); y1 date := make_date(p_year, 12, 31);
  v_base numeric; v_ent numeric; v_pr boolean := false;
  v_carry numeric; v_adj numeric; v_open numeric; v_used numeric; v_pend numeric;
begin
  select * into pr from public.profiles where id = p_user;
  select * into st from public.app_settings where id = 1;
  select * into e  from public.leave_entitlements x
   where x.user_id = p_user and x.year = p_year and x.kind = p_kind;

  v_base := coalesce(e.base_days,
              case p_kind when 'sick' then coalesce(pr.sick_days, st.default_sick_days)
                          else coalesce(pr.annual_days, st.default_annual_days) end);

  if pr.hire_date is null or pr.hire_date <= y0 then
    v_ent := v_base;
  elsif pr.hire_date > y1 then
    v_ent := 0; v_pr := true;
  else
    v_ent := (round(v_base * (y1 - pr.hire_date + 1)::numeric / (y1 - y0 + 1) * 2) / 2)::numeric(6,1);
    v_pr := true;
  end if;

  v_carry := coalesce(e.carried_over, 0); v_adj := coalesce(e.adjustment, 0); v_open := coalesce(e.opening_used, 0);

  select coalesce(sum(r.days) filter (where r.status = 'approved'), 0),
         coalesce(sum(r.days) filter (where r.status = 'pending'), 0)
    into v_used, v_pend
    from public.leave_requests r
    join public.leave_types t on t.code = r.type_code and t.balance_kind = p_kind
   where r.user_id = p_user and extract(year from r.start_date)::int = p_year;

  kind := p_kind; year := p_year; base := v_base; entitled := v_ent; prorated := v_pr;
  carried_over := v_carry; adjustment := v_adj; total := v_ent + v_carry + v_adj;
  used := v_used + v_open; pending := v_pend; available := total - used - v_pend;
  return next;
end $$;
revoke execute on function public._leave_balance(uuid, int, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. 只有"待审批"的申请可以撤回（员工本人或管理员）
--    已批准的休假只能通过"修改休假"调整日期
--    Seules les demandes en attente peuvent être annulées
-- ---------------------------------------------------------------------
create or replace function public.cancel_leave(p_id uuid, p_comment text default null)
returns public.leave_requests
language plpgsql security definer set search_path = public as $$
declare me public.profiles; r public.leave_requests;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.active then raise exception 'ERR_ACCOUNT_INACTIVE'; end if;

  select * into r from public.leave_requests where id = p_id for update;
  if r.id is null then raise exception 'ERR_NOT_FOUND'; end if;
  if not (r.user_id = me.id or me.role = 'admin') then raise exception 'ERR_FORBIDDEN'; end if;
  if r.status <> 'pending' then raise exception 'ERR_NOT_CANCELLABLE'; end if;

  update public.leave_requests
     set status = 'cancelled', decided_by = me.id, decided_by_name = me.full_name, decided_at = now(),
         decision_comment = coalesce(nullif(trim(p_comment), ''), decision_comment)
   where id = p_id
  returning * into r;

  insert into public.leave_events (request_id, actor_id, actor_name, action, comment)
  values (r.id, me.id, me.full_name, 'cancelled', nullif(trim(p_comment), ''));
  return r;
end $$;

commit;
