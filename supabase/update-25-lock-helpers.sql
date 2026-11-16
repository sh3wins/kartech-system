-- =====================================================================
--  UPDATE 25: close three small side doors (found by check-security.sql)
--  A few behind-the-scenes helper functions could be called by anyone on
--  the internet (not signed in). They only showed worker names for a
--  job id, so nothing serious, but strangers should not reach them.
--  This file closes every function to strangers EXCEPT the ones the
--  client pages need (Order Room, find my order, receipt check, website).
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again, and safe to run after any future update.
-- =====================================================================
do $$
declare f record;
  public_ok text[] := array['is_admin','kt_check','track_order','place_order','submit_custom_request',
                            'ws_find_rooms','ws_room','ws_room_add_photo','ws_room_approve',
                            'ws_room_message','ws_room_ok','ws_room_paid','touch_updated_at'];
begin
  for f in select p.oid::regprocedure as sig, p.proname
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and (p.proname like 'ws\_%' or p.proname like 'kt\_%')
              and not (p.proname = any (public_ok))
              and has_function_privilege('anon', p.oid, 'execute') loop
    -- keep signed-in access exactly as it was, only shut out strangers
    if has_function_privilege('authenticated', f.sig::oid, 'execute') then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
    execute format('revoke execute on function %s from public, anon', f.sig);
    raise notice 'closed to strangers: %', f.proname;
  end loop;
end $$;
