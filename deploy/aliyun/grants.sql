-- 自部署环境：确保登录用户和服务端可以访问本系统的表（实际数据访问仍由 RLS 控制）
-- Accès aux tables pour les rôles API (les règles RLS restent appliquées)
grant usage on schema public to authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated, service_role;
grant usage, select on all sequences in schema public to authenticated, service_role;
