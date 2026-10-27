-- Read-only metadata inventory. Run only after explicitly confirming the staging
-- project. This does not migrate schemas, reset data, or certify compatibility.
BEGIN READ ONLY;
SELECT current_database() AS database_name, current_user AS operator_role;
SELECT table_name, column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema='public'
  AND table_name IN ('profiles','videos','creator_wallets','coin_wallets','checkout_orders','coin_ledger','billing_subscriptions','platform_settings')
ORDER BY table_name, ordinal_position;
SELECT n.nspname AS schema_name,c.relname AS table_name,c.relrowsecurity AS rls_enabled
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE c.relkind='r' AND n.nspname IN ('public','storage') ORDER BY 1,2;
SELECT schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check
FROM pg_policies WHERE schemaname IN ('public','storage') ORDER BY 1,2,3;
SELECT t.tgrelid::regclass AS table_name,t.tgname AS trigger_name,
       t.tgfoid::regprocedure AS function_name,pg_get_triggerdef(t.oid) AS definition
FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE NOT t.tgisinternal AND n.nspname IN ('auth','public') ORDER BY 1,2;
SELECT grantee,table_name,privilege_type
FROM information_schema.role_table_grants
WHERE table_schema='public' AND grantee IN ('anon','authenticated','service_role') ORDER BY 2,1,3;
SELECT to_regclass('supabase_migrations.schema_migrations') AS migration_history_table;
-- Inspect history through authorized staging tooling if present. Do not mark
-- unexecuted migrations applied. Do not export profile rows or secret values.
COMMIT;
