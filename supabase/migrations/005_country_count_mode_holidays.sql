-- =====================================================================
-- 005 — 按国家设置天数计算方式；中国、新加坡、科特迪瓦 2026–2027 年公共假期
--       Mode de décompte par pays ; jours fériés Chine, Singapour, Côte d'Ivoire 2026–2027
--       Day-count method per country; CN / SG / CI public holidays 2026–2027
-- 在 SQL Editor 中整段运行一次（可重复运行）/ À exécuter une fois (ré-exécutable)
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. 国家的天数计算方式（留空 = 使用全局默认）
--    Mode de décompte par pays (vide = paramètre général)
-- ---------------------------------------------------------------------
alter table public.countries add column if not exists count_mode text
  check (count_mode in ('ouvrables','ouvres','calendaires'));

update public.countries set count_mode = v.m from (values
  ('GN','ouvrables'),   -- 几内亚：周一至周六 / Guinée : lundi–samedi
  ('CI','ouvrables'),   -- 科特迪瓦：周一至周六 / Côte d'Ivoire : lundi–samedi
  ('CN','ouvres'),      -- 中国：周一至周五 / Chine : lundi–vendredi
  ('SG','ouvres')       -- 新加坡：周一至周五 / Singapour : lundi–vendredi
) v(c, m) where code = v.c and count_mode is null;

-- ---------------------------------------------------------------------
-- 2. 调休上班日（周末补班，计入休假天数）
--    Jours ouvrés exceptionnels (week-end travaillé, décompté)
-- ---------------------------------------------------------------------
alter table public.holidays add column if not exists is_workday boolean not null default false;

-- ---------------------------------------------------------------------
-- 3. 天数计算：按员工工作国家的计算方式与假日
-- ---------------------------------------------------------------------
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
  v_country := coalesce(p_country,
                        (select pr.work_country from public.profiles pr where pr.id = auth.uid()),
                        'GN');
  select coalesce(c.count_mode, s.count_mode) into v_mode
    from public.app_settings s left join public.countries c on c.code = v_country
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

-- ---------------------------------------------------------------------
-- 4. 公共假期 / Jours fériés
-- ---------------------------------------------------------------------
insert into public.holidays (day, country_code, name_zh, name_fr, name_en, is_workday) values
-- ===== 中国 2026（国办发明电〔2025〕7号）=====
  ('2026-01-01','CN','元旦','Jour de l''An','New Year''s Day',false),
  ('2026-01-02','CN','元旦','Jour de l''An','New Year''s Day',false),
  ('2026-01-03','CN','元旦','Jour de l''An','New Year''s Day',false),
  ('2026-01-04','CN','调休上班','Jour travaillé (récupération)','Adjusted working day',true),
  ('2026-02-14','CN','调休上班','Jour travaillé (récupération)','Adjusted working day',true),
  ('2026-02-15','CN','春节','Nouvel An chinois','Spring Festival',false),
  ('2026-02-16','CN','春节','Nouvel An chinois','Spring Festival',false),
  ('2026-02-17','CN','春节','Nouvel An chinois','Spring Festival',false),
  ('2026-02-18','CN','春节','Nouvel An chinois','Spring Festival',false),
  ('2026-02-19','CN','春节','Nouvel An chinois','Spring Festival',false),
  ('2026-02-20','CN','春节','Nouvel An chinois','Spring Festival',false),
  ('2026-02-21','CN','春节','Nouvel An chinois','Spring Festival',false),
  ('2026-02-22','CN','春节','Nouvel An chinois','Spring Festival',false),
  ('2026-02-23','CN','春节','Nouvel An chinois','Spring Festival',false),
  ('2026-02-28','CN','调休上班','Jour travaillé (récupération)','Adjusted working day',true),
  ('2026-04-04','CN','清明节','Fête de Qingming','Qingming Festival',false),
  ('2026-04-05','CN','清明节','Fête de Qingming','Qingming Festival',false),
  ('2026-04-06','CN','清明节','Fête de Qingming','Qingming Festival',false),
  ('2026-05-01','CN','劳动节','Fête du Travail','Labour Day',false),
  ('2026-05-02','CN','劳动节','Fête du Travail','Labour Day',false),
  ('2026-05-03','CN','劳动节','Fête du Travail','Labour Day',false),
  ('2026-05-04','CN','劳动节','Fête du Travail','Labour Day',false),
  ('2026-05-05','CN','劳动节','Fête du Travail','Labour Day',false),
  ('2026-05-09','CN','调休上班','Jour travaillé (récupération)','Adjusted working day',true),
  ('2026-06-19','CN','端午节','Fête des Bateaux-Dragons','Dragon Boat Festival',false),
  ('2026-06-20','CN','端午节','Fête des Bateaux-Dragons','Dragon Boat Festival',false),
  ('2026-06-21','CN','端午节','Fête des Bateaux-Dragons','Dragon Boat Festival',false),
  ('2026-09-20','CN','调休上班','Jour travaillé (récupération)','Adjusted working day',true),
  ('2026-09-25','CN','中秋节','Fête de la Mi-Automne','Mid-Autumn Festival',false),
  ('2026-09-26','CN','中秋节','Fête de la Mi-Automne','Mid-Autumn Festival',false),
  ('2026-09-27','CN','中秋节','Fête de la Mi-Automne','Mid-Autumn Festival',false),
  ('2026-10-01','CN','国庆节','Fête nationale','National Day',false),
  ('2026-10-02','CN','国庆节','Fête nationale','National Day',false),
  ('2026-10-03','CN','国庆节','Fête nationale','National Day',false),
  ('2026-10-04','CN','国庆节','Fête nationale','National Day',false),
  ('2026-10-05','CN','国庆节','Fête nationale','National Day',false),
  ('2026-10-06','CN','国庆节','Fête nationale','National Day',false),
  ('2026-10-07','CN','国庆节','Fête nationale','National Day',false),
  ('2026-10-10','CN','调休上班','Jour travaillé (récupération)','Adjusted working day',true),
-- ===== 中国 2027：仅法定节日当天（国务院放假安排预计 2026 年底公布，届时补充调休）=====
-- Chine 2027 : jours légaux uniquement, provisoire / provisional statutory days only
  ('2027-01-01','CN','元旦（暂定）','Jour de l''An (provisoire)','New Year''s Day (provisional)',false),
  ('2027-02-05','CN','除夕（暂定）','Veille du Nouvel An chinois (provisoire)','Chinese New Year''s Eve (provisional)',false),
  ('2027-02-06','CN','春节（暂定）','Nouvel An chinois (provisoire)','Spring Festival (provisional)',false),
  ('2027-02-07','CN','春节（暂定）','Nouvel An chinois (provisoire)','Spring Festival (provisional)',false),
  ('2027-02-08','CN','春节（暂定）','Nouvel An chinois (provisoire)','Spring Festival (provisional)',false),
  ('2027-04-05','CN','清明节（暂定）','Fête de Qingming (provisoire)','Qingming Festival (provisional)',false),
  ('2027-05-01','CN','劳动节（暂定）','Fête du Travail (provisoire)','Labour Day (provisional)',false),
  ('2027-05-02','CN','劳动节（暂定）','Fête du Travail (provisoire)','Labour Day (provisional)',false),
  ('2027-06-09','CN','端午节（暂定）','Fête des Bateaux-Dragons (provisoire)','Dragon Boat Festival (provisional)',false),
  ('2027-09-15','CN','中秋节（暂定）','Fête de la Mi-Automne (provisoire)','Mid-Autumn Festival (provisional)',false),
  ('2027-10-01','CN','国庆节（暂定）','Fête nationale (provisoire)','National Day (provisional)',false),
  ('2027-10-02','CN','国庆节（暂定）','Fête nationale (provisoire)','National Day (provisional)',false),
  ('2027-10-03','CN','国庆节（暂定）','Fête nationale (provisoire)','National Day (provisional)',false),
-- ===== 新加坡 2026（MOM）=====
  ('2026-01-01','SG','元旦','Jour de l''An','New Year''s Day',false),
  ('2026-02-17','SG','农历新年','Nouvel An chinois','Chinese New Year',false),
  ('2026-02-18','SG','农历新年','Nouvel An chinois','Chinese New Year',false),
  ('2026-03-21','SG','开斋节','Hari Raya Puasa','Hari Raya Puasa',false),
  ('2026-04-03','SG','耶稣受难日','Vendredi saint','Good Friday',false),
  ('2026-05-01','SG','劳动节','Fête du Travail','Labour Day',false),
  ('2026-05-27','SG','哈芝节','Hari Raya Haji','Hari Raya Haji',false),
  ('2026-05-31','SG','卫塞节','Vesak','Vesak Day',false),
  ('2026-06-01','SG','卫塞节补假','Vesak (jour de remplacement)','Vesak Day (in lieu)',false),
  ('2026-08-09','SG','国庆日','Fête nationale','National Day',false),
  ('2026-08-10','SG','国庆日补假','Fête nationale (jour de remplacement)','National Day (in lieu)',false),
  ('2026-11-08','SG','屠妖节','Deepavali','Deepavali',false),
  ('2026-11-09','SG','屠妖节补假','Deepavali (jour de remplacement)','Deepavali (in lieu)',false),
  ('2026-12-25','SG','圣诞节','Noël','Christmas Day',false),
-- ===== 新加坡 2027（MOM, 2026-06-18 公布）=====
  ('2027-01-01','SG','元旦','Jour de l''An','New Year''s Day',false),
  ('2027-02-06','SG','农历新年','Nouvel An chinois','Chinese New Year',false),
  ('2027-02-07','SG','农历新年','Nouvel An chinois','Chinese New Year',false),
  ('2027-02-08','SG','农历新年补假','Nouvel An chinois (jour de remplacement)','Chinese New Year (in lieu)',false),
  ('2027-03-10','SG','开斋节','Hari Raya Puasa','Hari Raya Puasa',false),
  ('2027-03-26','SG','耶稣受难日','Vendredi saint','Good Friday',false),
  ('2027-05-01','SG','劳动节','Fête du Travail','Labour Day',false),
  ('2027-05-17','SG','哈芝节','Hari Raya Haji','Hari Raya Haji',false),
  ('2027-05-20','SG','卫塞节','Vesak','Vesak Day',false),
  ('2027-08-09','SG','国庆日','Fête nationale','National Day',false),
  ('2027-10-28','SG','屠妖节','Deepavali','Deepavali',false),
  ('2027-12-25','SG','圣诞节','Noël','Christmas Day',false),
-- ===== 科特迪瓦 2026（官方日历）=====
  ('2026-01-01','CI','元旦','Jour de l''An','New Year''s Day',false),
  ('2026-03-15','CI','盖德尔夜','Nuit du Destin','Night of Destiny',false),
  ('2026-03-16','CI','盖德尔夜次日','Lendemain de la Nuit du Destin','Day after the Night of Destiny',false),
  ('2026-03-20','CI','开斋节','Aïd el-Fitr (Ramadan)','Eid al-Fitr',false),
  ('2026-04-05','CI','复活节','Pâques','Easter Sunday',false),
  ('2026-04-06','CI','复活节星期一','Lundi de Pâques','Easter Monday',false),
  ('2026-05-01','CI','劳动节','Fête du Travail','Labour Day',false),
  ('2026-05-14','CI','耶稣升天节','Ascension','Ascension Day',false),
  ('2026-05-24','CI','圣灵降临节','Pentecôte','Pentecost',false),
  ('2026-05-25','CI','圣灵降临节星期一','Lundi de Pentecôte','Whit Monday',false),
  ('2026-05-27','CI','宰牲节','Tabaski (Aïd el-Kébir)','Eid al-Adha',false),
  ('2026-08-07','CI','独立日','Fête nationale','Independence Day',false),
  ('2026-08-15','CI','圣母升天节','Assomption','Assumption Day',false),
  ('2026-08-24','CI','圣纪节','Maouloud','Mawlid',false),
  ('2026-08-25','CI','圣纪节次日','Lendemain du Maouloud','Day after Mawlid',false),
  ('2026-11-01','CI','诸圣节','Toussaint','All Saints'' Day',false),
  ('2026-11-15','CI','全国和平日','Journée nationale de la Paix','National Peace Day',false),
  ('2026-12-25','CI','圣诞节','Noël','Christmas Day',false),
-- ===== 科特迪瓦 2027：固定日期 + 伊斯兰节日预估（以政府公布为准）=====
  ('2027-01-01','CI','元旦','Jour de l''An','New Year''s Day',false),
  ('2027-03-10','CI','开斋节（预估）','Aïd el-Fitr (date estimée)','Eid al-Fitr (estimated)',false),
  ('2027-03-28','CI','复活节','Pâques','Easter Sunday',false),
  ('2027-03-29','CI','复活节星期一','Lundi de Pâques','Easter Monday',false),
  ('2027-05-01','CI','劳动节','Fête du Travail','Labour Day',false),
  ('2027-05-06','CI','耶稣升天节','Ascension','Ascension Day',false),
  ('2027-05-16','CI','圣灵降临节','Pentecôte','Pentecost',false),
  ('2027-05-17','CI','圣灵降临节星期一 / 宰牲节（预估）','Lundi de Pentecôte / Tabaski (date estimée)','Whit Monday / Eid al-Adha (estimated)',false),
  ('2027-08-07','CI','独立日','Fête nationale','Independence Day',false),
  ('2027-08-15','CI','圣母升天节','Assomption','Assumption Day',false),
  ('2027-08-16','CI','圣纪节次日（预估）','Lendemain du Maouloud (date estimée)','Day after Mawlid (estimated)',false),
  ('2027-11-01','CI','诸圣节','Toussaint','All Saints'' Day',false),
  ('2027-11-15','CI','全国和平日','Journée nationale de la Paix','National Peace Day',false),
  ('2027-12-25','CI','圣诞节','Noël','Christmas Day',false)
on conflict (day, country_code) do nothing;

commit;
