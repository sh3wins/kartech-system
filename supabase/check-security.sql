-- =====================================================================
--  KARTECH: SECURITY CHECK (read-only: it changes nothing)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  You get one table. Every row should say PASS.
--  Any FAIL: stop and fix it before real customers use the system.
--  Any CHECK: read the note, it needs a person to look.
--
--  It checks the database rules, and it also pretends to be:
--    • a stranger on the internet (not signed in),
--    • the workshop computer's account,
--    • the owner,
--  and counts what each one can see. Nothing is saved.
-- =====================================================================
create or replace function pg_temp.kartech_security_check()
returns table (nr int, area text, check_name text, result text, note text)
language plpgsql as $chk$
declare
  r record; n bigint; total bigint; bad text;
  station uuid := (select user_id from public.ws_stations limit 1);
  owner_id uuid := (select user_id from public.admins limit 1);
  -- functions a stranger (the client's Order Room, the receipt check page,
  -- the website) is ALLOWED to call. Each one checks a secret code itself.
  public_ok text[] := array['is_admin','kt_check','track_order','place_order','submit_custom_request',
                            'ws_find_rooms','ws_room','ws_room_add_photo','ws_room_approve',
                            'ws_room_message','ws_room_ok','ws_room_paid','touch_updated_at'];
begin
  -- 1. every table has its lock (row level security) switched on
  select string_agg(c.relname, ', ') into bad
    from pg_class c join pg_namespace s on s.oid = c.relnamespace
   where s.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  nr := 1; area := 'Database'; check_name := 'Every table is locked (row level security on)';
  result := case when bad is null then 'PASS' else 'FAIL' end;
  note := coalesce('Not locked: ' || bad, 'All tables locked'); return next;

  -- 2. nobody but the owner can read money tables
  select string_agg(p.tablename || ' → ' || p.policyname, '; ') into bad
    from pg_policies p
   where p.schemaname = 'public' and p.tablename in ('kt_invoices','kt_payments','kt_counters')
     and coalesce(p.qual, '') not like '%is_admin()%';
  nr := 2; area := 'Money'; check_name := 'Invoice and payment tables: only the owner may read';
  result := case when bad is null then 'PASS' else 'FAIL' end;
  note := coalesce('Rules that let others in: ' || bad, 'Only the owner'); return next;

  -- 3. nobody can write money tables directly (only through owner-only functions)
  select string_agg(t || ' (' || g || ')', ', ') into bad
    from unnest(array['kt_invoices','kt_payments','kt_counters']) t,
         unnest(array['anon','authenticated']) g
   where to_regclass('public.' || t) is not null
     and (has_table_privilege(g, 'public.' || t, 'INSERT') or has_table_privilege(g, 'public.' || t, 'UPDATE')
          or has_table_privilege(g, 'public.' || t, 'DELETE'));
  nr := 3; area := 'Money'; check_name := 'Nobody can change invoices or payments directly';
  result := case when bad is null then 'PASS' else 'FAIL' end;
  note := coalesce('Can write: ' || bad, 'Only through the owner''s buttons'); return next;

  -- 4. strangers can only call the functions on the allowed list
  select string_agg(distinct p.proname, ', ') into bad
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and not (p.proname = any (public_ok));
  nr := 4; area := 'Database'; check_name := 'Strangers can only use the client-page functions';
  result := case when bad is null then 'PASS' else 'FAIL' end;
  note := coalesce('Open to strangers but should not be: ' || bad, 'Only Order Room, receipt check and website functions'); return next;

  -- 5. workers' pictures bucket is private
  select count(*) into n from storage.buckets where id = 'kartech-photos' and not public;
  nr := 5; area := 'Files'; check_name := 'Order pictures folder (kartech-photos) is private';
  result := case when n = 1 then 'PASS' else 'FAIL' end;
  note := case when n = 1 then 'Private' else 'Missing or public' end; return next;

  select count(*) into n from storage.buckets where id = 'room-files' and public;
  nr := 6; area := 'Files'; check_name := 'Client Order Room files (room-files)';
  result := 'CHECK';
  note := case when n = 1 then 'Public on purpose: each file sits under a long secret code, so only someone with the client''s link can find it. Never put invoices or receipts there.'
               else 'Bucket missing or private: client pictures will not show. Run update-16.' end; return next;

  -- 7. the owner and the workshop computer are set up
  nr := 7; area := 'Accounts'; check_name := 'An owner account exists';
  select count(*) into n from public.admins;
  result := case when n >= 1 then 'PASS' else 'FAIL' end; note := n || ' owner account(s)'; return next;

  nr := 8; area := 'Accounts'; check_name := 'The workshop computer account exists';
  select count(*) into n from public.ws_stations;
  result := case when n >= 1 then 'PASS' else 'FAIL' end; note := n || ' workshop account(s)'; return next;

  nr := 9; area := 'Accounts'; check_name := 'The workshop account is NOT also an owner';
  select count(*) into n from public.ws_stations s join public.admins a on a.user_id = s.user_id;
  result := case when n = 0 then 'PASS' else 'FAIL' end;
  note := case when n = 0 then 'Separate' else 'The workshop computer would see all the money. Remove it from admins.' end; return next;

  -- 10–14. pretend to be a stranger (not signed in)
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
  for r in select * from (values (10,'kt_invoices','invoices'),(11,'kt_payments','payments'),(12,'ws_orders','workshop orders'),
                                 (13,'ws_workers','workers and PINs'),(14,'orders','website orders')) v(i, t, label) loop
    begin
      execute format('select count(*) from public.%I', r.t) into n;
      nr := r.i; area := 'Stranger'; check_name := 'A stranger can see ' || r.label;
      result := case when n = 0 then 'PASS' else 'FAIL' end; note := n || ' rows visible (must be 0)';
    exception when insufficient_privilege or undefined_table then
      nr := r.i; area := 'Stranger'; check_name := 'A stranger can see ' || r.label; result := 'PASS'; note := 'Blocked';
    end;
    return next;
  end loop;
  execute 'reset role';

  -- 15–17. pretend to be the workshop computer
  if station is null then
    nr := 15; area := 'Workshop PC'; check_name := 'The workshop computer cannot see money'; result := 'CHECK';
    note := 'No workshop account yet, so this could not be tested. Set it up (README step 3) and run again.'; return next;
  else
    perform set_config('request.jwt.claim.sub', station::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', station, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    for r in select * from (values (15,'kt_invoices','invoices'),(16,'kt_payments','payments'),(17,'ws_workers','workers and PINs')) v(i, t, label) loop
      begin
        execute format('select count(*) from public.%I', r.t) into n;
        nr := r.i; area := 'Workshop PC'; check_name := 'The workshop computer can see ' || r.label;
        result := case when n = 0 then 'PASS' else 'FAIL' end; note := n || ' rows visible (must be 0)';
      exception when insufficient_privilege or undefined_table then
        nr := r.i; area := 'Workshop PC'; check_name := 'The workshop computer can see ' || r.label; result := 'PASS'; note := 'Blocked';
      end;
      return next;
    end loop;
    execute 'reset role';
  end if;

  -- 18. pretend to be the owner: she must see every invoice
  if owner_id is null then
    nr := 18; area := 'Owner'; check_name := 'The owner sees all invoices'; result := 'CHECK'; note := 'No owner account yet.'; return next;
  else
    select count(*) into total from public.kt_invoices;
    perform set_config('request.jwt.claim.sub', owner_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into n from public.kt_invoices;
    execute 'reset role';
    nr := 18; area := 'Owner'; check_name := 'The owner sees all invoices';
    result := case when n = total then 'PASS' else 'FAIL' end; note := n || ' of ' || total || ' invoices'; return next;
  end if;

  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
end $chk$;

select * from pg_temp.kartech_security_check() order by nr;
