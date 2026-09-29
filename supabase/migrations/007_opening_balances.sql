-- =====================================================================
-- 007 — 初始化数据：本年在系统上线前已休的天数
--       Données initiales : jours déjà pris avant la mise en service
--       Opening data: days already taken before go-live
-- 可重复运行 / ré-exécutable
-- =====================================================================
begin;

alter table public.leave_entitlements
  add column if not exists opening_used numeric(5,1) not null default 0;
alter table public.leave_entitlements drop constraint if exists leave_entitlements_opening_used_check;
alter table public.leave_entitlements add constraint leave_entitlements_opening_used_check check (opening_used >= 0);

-- 已休天数 = 系统内已批准 + 系统外已休（初始化）
-- Jours pris = approuvés dans la plateforme + déjà pris hors plateforme
create or replace function public._leave_balance(p_user uuid, p_year int, p_kind text)
returns table (kind text, year int, base numeric, entitled numeric, prorated boolean,
               carried_over numeric, adjustment numeric, total numeric,
               used numeric, pending numeric, available numeric)
language plpgsql stable security definer set search_path = public as $$
declare
  pr public.profiles; st public.app_settings;
  y0 date := make_date(p_year, 1, 1); y1 date := make_date(p_year, 12, 31);
  v_base numeric; v_ent numeric; v_pr boolean := false;
  v_carry numeric := 0; v_adj numeric := 0; v_open numeric := 0; v_used numeric; v_pend numeric;
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
    v_ent := (round(v_base * (y1 - pr.hire_date + 1)::numeric / (y1 - y0 + 1) * 2) / 2)::numeric(6,1);
    v_pr := true;
  end if;

  select coalesce(e.carried_over, 0), coalesce(e.adjustment, 0), coalesce(e.opening_used, 0)
    into v_carry, v_adj, v_open
    from public.leave_entitlements e
   where e.user_id = p_user and e.year = p_year and e.kind = p_kind;
  v_carry := coalesce(v_carry, 0); v_adj := coalesce(v_adj, 0); v_open := coalesce(v_open, 0);

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

commit;
