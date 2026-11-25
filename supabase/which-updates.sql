-- =====================================================================
--  KARTECH: WHICH DATABASE UPDATES ARE IN THIS PROJECT? (read-only)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Every row should say "yes". Any "MISSING": run that file next
--  (lowest number first), or run INSTALL-ALL.sql to catch up on all.
-- =====================================================================
select nr, file, about, case when ok then 'yes' else 'MISSING' end as installed
from (values
  (0, 'setup-workshop.sql', 'WORKSHOP SYSTEM: database setup', to_regclass('public.ws_workers') is not null),
  (1, 'update-1-website-link.sql', 'UPDATE 1: website orders join the workshop + tap-your-name sign in', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ws_orders' and column_name = 'source_order_id')),
  (2, 'update-2-materials.sql', 'UPDATE 2: raw materials (store, giving out, theft checks)', to_regclass('public.ws_materials') is not null),
  (3, 'update-3-tools.sql', 'UPDATE 3: tools (grinders, welders, drills…) evening check', to_regclass('public.ws_tools') is not null),
  (4, 'update-4-foreman.sql', 'UPDATE 4: the foreman page on the workshop screen', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ws_materials' and column_name = 'stages')),
  (5, 'update-5-steps.sql', 'UPDATE 5: workshop steps the owner can change', to_regclass('public.ws_steps') is not null),
  (6, 'update-6-attendance.sql', 'UPDATE 6: who is here today + the owner can give a job to anyone', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ws_workers' and column_name = 'away_on')),
  (7, 'update-7-checkin.sql', 'UPDATE 7: morning check-in by the foreman + tools per trade', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ws_workers' and column_name = 'arrived_on')),
  (8, 'update-8-history.sql', 'UPDATE 8: History (owner app → History)', to_regclass('public.ws_attendance') is not null),
  (9, 'update-9-edit-orders.sql', 'UPDATE 9: pick who does each step + edit or delete an order', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ws_tasks' and column_name = 'planned')),
  (10, 'update-10-kartech-items.sql', 'UPDATE 10: Kartech''s real tools and materials', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ws_materials' and column_name = 'counted')),
  (11, 'update-11-together.sql', 'UPDATE 11: steps at the same time + pick people for later steps', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ws_tasks' and column_name = 'with_prev')),
  (12, 'update-12-all.sql', 'UPDATE 12: job alerts, deliveries, photos', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'ws_station_board')),
  (13, 'update-13-manager.sql', 'UPDATE 13: "Foreman" is now called "Manager"', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'ws_station_board') and not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prosrc like '%Foreman gave %')),
  (14, 'update-14-order-pictures.sql', 'UPDATE 14: pictures of what to make (workers see them)', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ws_photos' and column_name = 'kind')),
  (15, 'update-15-sales.sql', 'UPDATE 15: the manager takes sales + quote requests in the app', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ws_orders' and column_name = 'created_by')),
  (16, 'update-16-order-room.sql', 'UPDATE 16: the Order Room (stage 1)', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'ws_new_code')),
  (17, 'update-17-client-links.sql', 'UPDATE 17: the manager can send any client their Order Room link', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'ws_foreman_rooms')),
  (18, 'update-18-payments.sql', 'UPDATE 18: invoice and payments, WITHOUT any money amounts', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'ws_orders' and column_name = 'on_hold')),
  (19, 'update-19-fix-client-photos.sql', 'UPDATE 19: fix "permission denied for table ws_orders" when a client', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'ws_room_ok')),
  (20, 'update-20-find-my-order.sql', 'UPDATE 20: a client finds their order with their phone number', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'ws_find_rooms')),
  (21, 'update-21-bin.sql', 'UPDATE 21: the Bin 🗑', to_regclass('public.ws_bin') is not null),
  (22, 'update-22-simple-assign.sql', 'UPDATE 22: simple assigning — the owner can mark a step done', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'ws_owner_done')),
  (23, 'update-23-invoices-receipts.sql', 'UPDATE 23: invoices and official receipts (with amounts)', to_regclass('public.kt_invoices') is not null),
  (24, 'update-24-manager-done.sql', 'UPDATE 24: the manager can mark a worker''s job done', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'ws_foreman_done')),
  (25, 'update-25-lock-helpers.sql', 'UPDATE 25: close three small side doors (found by check-security.sql)', exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'ws_task_names') and not has_function_privilege('anon', 'public.ws_task_names(uuid)', 'execute')),
  (26, 'update-26-shop-products.sql', 'UPDATE 26: the owner runs the website shop from her app', to_regclass('public.kt_products') is not null)
) v(nr, file, about, ok)
order by nr;
