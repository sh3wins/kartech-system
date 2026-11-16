-- =====================================================================
--  KARTECH: BUSINESS RULE TESTS
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  You get one table. Every row should say PASS.
--
--  What it does: it makes a pretend order ("TEST CUSTOMER"), sends an
--  invoice, records payments, tries things the workshop computer and
--  strangers must NOT be able to do, and checks every answer.
--  At the end it UNDOES EVERYTHING. No test order, invoice or receipt
--  is kept, and no message reaches any client.
--  (The only trace: one order number, like KT-1050, is skipped.)
--
--  Run it after every database update, before telling the owner it's live.
-- =====================================================================
create or replace function pg_temp.kartech_tests()
returns table (nr int, test text, result text, note text)
language plpgsql as $t$
declare
  res text[] := '{}';          -- each entry: 'PASS|name|note' or 'FAIL|name|note'
  owner_id uuid; station_id uuid; w_id uuid;
  o_ref text; o_id uuid; o public.ws_orders; inv jsonb; inv_id uuid; pay jsonb; p1 uuid; p2 uuid;
  j jsonb; n int; msg text; seq_last bigint; seq_called boolean; i int := 0;
  undo constant text := 'kartech-test-undo';

begin
  select last_value, is_called into seq_last, seq_called from public.ws_ref_seq;

  begin  -- ======== everything in here is undone at the end ========

    -- people to pretend to be (made up just for the test if missing)
    select user_id into owner_id from public.admins limit 1;
    if owner_id is null then
      owner_id := gen_random_uuid();
      insert into auth.users (id, email) values (owner_id, 'test-owner@kartech.invalid');
      insert into public.admins (user_id) values (owner_id);
    end if;
    select user_id into station_id from public.ws_stations limit 1;
    if station_id is null then
      station_id := gen_random_uuid();
      insert into auth.users (id, email) values (station_id, 'test-station@kartech.invalid');
      insert into public.ws_stations (user_id) values (station_id);
    end if;

    -- ---------- as the OWNER ----------
    perform set_config('request.jwt.claim.sub', owner_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';

    o_ref := public.ws_create_order(jsonb_build_object('customer', 'TEST CUSTOMER', 'item', 'Test chairs', 'qty', 3,
               'stages', (select jsonb_agg(id) from (select id from public.ws_steps where active order by sort limit 2) s)));
    select * into o from public.ws_orders where ref = o_ref; o_id := o.id;
    res := res || format('%s|Owner can create an order|%s made', case when o_id is not null then 'PASS' else 'FAIL' end, o_ref);
    res := res || format('%s|A new order waits for the deposit (on hold)|on_hold = %s', case when o.on_hold then 'PASS' else 'FAIL' end, o.on_hold);
    select count(*) into n from public.ws_tasks where order_id = o_id and status in ('assigned', 'working');
    res := res || format('%s|No worker gets the job before a deposit|%s steps given out', case when n = 0 then 'PASS' else 'FAIL' end, n);

    -- invoice
    begin
      inv := public.kt_save_invoice(o_id, jsonb_build_object('phone', '0700000000',
               'items', jsonb_build_array(jsonb_build_object('desc', 'Test chairs', 'qty', 3, 'price', 1500),
                                          jsonb_build_object('desc', 'Delivery', 'qty', 1, 'price', 500))));
      inv_id := (inv->>'id')::uuid;
      res := res || format('%s|Owner can make an invoice, total is worked out right|%s, total %s (should be 5000)',
                           case when (inv->>'total')::numeric = 5000 then 'PASS' else 'FAIL' end, inv->>'no', inv->>'total');
      res := res || format('%s|Invoice number looks like INV-YEAR-0001|%s',
                           case when inv->>'no' ~ '^INV-\d{4}-\d{4,}$' then 'PASS' else 'FAIL' end, inv->>'no');
    exception when others then res := res || ('FAIL|Owner can make an invoice|' || sqlerrm); end;

    begin
      perform public.kt_save_invoice(o_id, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('desc', 'Bad', 'qty', 0, 'price', 10))));
      res := res || 'FAIL|An invoice line with quantity 0 is refused|it was accepted'::text;
    exception when others then res := res || ('PASS|An invoice line with quantity 0 is refused|' || sqlerrm); end;

    -- delivery before payment
    execute 'reset role';
    update public.ws_tasks set status = 'done', done_at = now() where order_id = o_id;  -- pretend the work is finished
    execute 'set local role authenticated';
    begin
      perform public.ws_deliver(o_id);
      res := res || 'FAIL|An order cannot be delivered before it is fully paid|it was marked delivered'::text;
    exception when others then res := res || ('PASS|An order cannot be delivered before it is fully paid|' || sqlerrm); end;
    execute 'reset role';
    update public.ws_tasks set status = 'queued', done_at = null where order_id = o_id;
    execute 'set local role authenticated';

    -- payments
    begin
      perform public.kt_record_payment(inv_id, 9000, 'Cash', null);
      res := res || 'FAIL|Paying more than the balance is refused|it was accepted'::text;
    exception when others then res := res || ('PASS|Paying more than the balance is refused|' || sqlerrm); end;

    begin
      perform public.kt_record_payment(inv_id, 1000, 'M-Pesa', '');
      res := res || 'FAIL|M-Pesa needs its code|accepted without a code'::text;
    exception when others then res := res || ('PASS|M-Pesa needs its code|' || sqlerrm); end;

    pay := public.kt_record_payment(inv_id, 2000, 'M-Pesa', 'TESTQ1W2E3'); p1 := (pay->'payment'->>'id')::uuid;
    select * into o from public.ws_orders where id = o_id;
    res := res || format('%s|A part payment gives a receipt with the right balance|paid %s, balance %s (should be 2000 and 3000)',
                         case when (pay->>'paid')::numeric = 2000 and (pay->>'balance')::numeric = 3000 then 'PASS' else 'FAIL' end, pay->>'paid', pay->>'balance');
    res := res || format('%s|The first payment starts the work (deposit confirmed)|on_hold = %s, deposit ok = %s',
                         case when not o.on_hold and o.dep_ok_at is not null then 'PASS' else 'FAIL' end, o.on_hold, o.dep_ok_at is not null);
    res := res || format('%s|After a part payment the order is not "fully paid" yet|paid_at set = %s',
                         case when o.paid_at is null then 'PASS' else 'FAIL' end, o.paid_at is not null);

    begin
      perform public.kt_record_payment(inv_id, 100, 'M-Pesa', 'testq1w2e3');
      res := res || 'FAIL|The same M-Pesa code cannot be used twice|it was accepted'::text;
    exception when others then res := res || ('PASS|The same M-Pesa code cannot be used twice|' || sqlerrm); end;

    pay := public.kt_record_payment(inv_id, 3000, 'Cash', null); p2 := (pay->'payment'->>'id')::uuid;
    -- (inside one test everything happens in the same second, so space the two receipts out)
    execute 'reset role';
    update public.kt_payments set created_at = created_at + interval '1 second' where id = p2;
    execute 'set local role authenticated';
    select * into o from public.ws_orders where id = o_id;
    res := res || format('%s|Paying the rest makes the order fully paid|balance %s, paid_at set = %s',
                         case when (pay->>'balance')::numeric = 0 and o.paid_at is not null then 'PASS' else 'FAIL' end, pay->>'balance', o.paid_at is not null);

    begin
      perform public.kt_cancel_payment(p1);
      res := res || 'FAIL|Only the newest receipt can be cancelled|an older one was cancelled'::text;
    exception when others then res := res || ('PASS|Only the newest receipt can be cancelled|' || sqlerrm); end;

    perform public.kt_cancel_payment(p2);
    select * into o from public.ws_orders where id = o_id;
    res := res || format('%s|Cancelling the last receipt takes back "fully paid"|paid_at set = %s',
                         case when o.paid_at is null then 'PASS' else 'FAIL' end, o.paid_at is not null);
    pay := public.kt_record_payment(inv_id, 3000, 'Cash', null);

    -- receipt check page (anyone can check a receipt is genuine)
    j := public.kt_check((select check_code from public.kt_payments where id = p1));
    res := res || format('%s|The "is this receipt genuine?" check finds a real receipt|%s',
                         case when j is not null and j::text <> 'null' then 'PASS' else 'FAIL' end, left(coalesce(j::text, 'nothing found'), 60));
    j := public.kt_check('not-a-real-code');
    res := res || format('%s|The genuine check says no to a made-up code|%s',
                         case when j is null or j::text = 'null' or j::text ilike '%false%' then 'PASS' else 'FAIL' end, coalesce(j::text, 'nothing found'));

    execute 'reset role';

    -- ---------- the client's Order Room shows NO amounts ----------
    j := public.ws_room(o.room_code);
    res := res || format('%s|The client''s Order Room shows no money amounts|%s',
                         case when j::text !~ '(5000|3000|2000|5,000|3,000|2,000)' then 'PASS' else 'FAIL' end,
                         case when j::text !~ '(5000|3000|2000|5,000|3,000|2,000)' then 'no amounts in it' else 'an amount was found' end);

    -- ---------- as the WORKSHOP COMPUTER ----------
    perform set_config('request.jwt.claim.sub', station_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', station_id, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';

    begin
      perform public.kt_record_payment(inv_id, 1, 'Cash', null);
      res := res || 'FAIL|The workshop computer cannot record a payment|it was accepted'::text;
    exception when others then res := res || ('PASS|The workshop computer cannot record a payment|' || sqlerrm); end;
    begin
      perform public.kt_save_invoice(o_id, jsonb_build_object('items', jsonb_build_array(jsonb_build_object('desc', 'x', 'qty', 1, 'price', 1))));
      res := res || 'FAIL|The workshop computer cannot make or change an invoice|it was accepted'::text;
    exception when others then res := res || ('PASS|The workshop computer cannot make or change an invoice|' || sqlerrm); end;
    begin
      perform public.ws_create_order(jsonb_build_object('customer', 'X', 'item', 'Y', 'stages', '["cut"]'::jsonb));
      res := res || 'FAIL|The workshop computer cannot add an order as the owner|it was accepted'::text;
    exception when others then res := res || ('PASS|The workshop computer cannot add an order as the owner|' || sqlerrm); end;
    select count(*) into n from public.kt_invoices;
    res := res || format('%s|The workshop computer sees 0 invoices|%s visible', case when n = 0 then 'PASS' else 'FAIL' end, n);
    begin
      j := public.ws_foreman_open('0000-wrong');
      res := res || format('%s|A wrong manager code is refused|%s', case when j ? 'error' then 'PASS' else 'FAIL' end, coalesce(j->>'error', 'it opened'));
    exception when others then res := res || ('PASS|A wrong manager code is refused|' || sqlerrm); end;
    execute 'reset role';

    -- ---------- as a STRANGER (not signed in) ----------
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    execute 'set local role anon';
    begin
      perform public.kt_record_payment(inv_id, 1, 'Cash', null);
      res := res || 'FAIL|A stranger cannot record a payment|it was accepted'::text;
    exception when others then res := res || ('PASS|A stranger cannot record a payment|' || sqlerrm); end;
    begin
      perform public.ws_delete_order(o_id);
      res := res || 'FAIL|A stranger cannot delete an order|it was deleted'::text;
    exception when others then res := res || ('PASS|A stranger cannot delete an order|' || sqlerrm); end;
    begin
      j := public.ws_room(o.room_code);
      res := res || format('%s|A client with the link can open their Order Room|%s', case when j->>'ref' = o_ref then 'PASS' else 'FAIL' end, coalesce(j->>'ref', 'not found'));
    exception when others then res := res || ('FAIL|A client with the link can open their Order Room|' || sqlerrm); end;
    begin
      j := public.ws_room('wrong-code-123');
      res := res || format('%s|A wrong Order Room link shows nothing|%s', case when j is null then 'PASS' else 'FAIL' end, coalesce(j->>'ref', 'nothing'));
    exception when others then res := res || ('PASS|A wrong Order Room link shows nothing|' || sqlerrm); end;
    execute 'reset role';

    -- ---------- as the OWNER again: the Bin ----------
    perform set_config('request.jwt.claim.sub', owner_id::text, true);
    perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    perform public.ws_delete_order(o_id);
    select count(*) into n from public.ws_orders where id = o_id;
    res := res || format('%s|Deleting an order removes it from the list|%s left', case when n = 0 then 'PASS' else 'FAIL' end, n);
    select count(*) into n from public.ws_bin where kind = 'order' and label ilike '%' || o_ref || '%';
    if n = 0 then select count(*) into n from public.ws_bin where data::text ilike '%' || o_ref || '%'; end if;
    res := res || format('%s|A deleted order goes to the Bin|%s in the Bin', case when n >= 1 then 'PASS' else 'FAIL' end, n);
    begin
      perform public.ws_bin_restore((select id from public.ws_bin where data::text ilike '%' || o_ref || '%' order by id desc limit 1));
      select count(*) into n from public.ws_orders where ref = o_ref;
      res := res || format('%s|An order can be brought back from the Bin|%s found again', case when n = 1 then 'PASS' else 'FAIL' end, n);
    exception when others then res := res || ('FAIL|An order can be brought back from the Bin|' || sqlerrm); end;
    execute 'reset role';

    raise exception using message = undo;   -- undo everything above
  exception when others then
    if sqlerrm <> undo then res := res || ('FAIL|The tests stopped early|' || sqlerrm); end if;
  end;

  perform setval('public.ws_ref_seq', seq_last, seq_called);   -- give back the order number
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);

  foreach msg in array res loop
    i := i + 1; nr := i; result := split_part(msg, '|', 1); test := split_part(msg, '|', 2);
    note := substr(msg, length(result) + length(test) + 3); return next;
  end loop;
end $t$;

select * from pg_temp.kartech_tests() order by nr;
