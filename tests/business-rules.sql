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

    -- ---------- shop products (update 26) ----------
    if to_regclass('public.kt_products') is not null then
      perform set_config('request.jwt.claim.sub', '', true);
      perform set_config('request.jwt.claims', '{"role":"anon"}', true);
      execute 'set local role anon';
      begin
        perform public.kt_save_product('{"name":"Hack"}'::jsonb);
        res := res || 'FAIL|A stranger cannot add a shop product|it was added'::text;
      exception when others then res := res || ('PASS|A stranger cannot add a shop product|' || sqlerrm); end;
      execute 'reset role';
      perform set_config('request.jwt.claim.sub', station_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', station_id, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      begin
        perform public.kt_save_product('{"name":"Hack"}'::jsonb);
        res := res || 'FAIL|The workshop computer cannot change the shop|it was added'::text;
      exception when others then res := res || ('PASS|The workshop computer cannot change the shop|' || sqlerrm); end;
      execute 'reset role';
      perform set_config('request.jwt.claim.sub', owner_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      msg := public.kt_save_product('{"name":"TEST hidden piece","price":"1200","active":false}'::jsonb);
      res := res || format('%s|The owner can add a shop product with a price|%s', case when (select price from public.kt_products where id = msg) = 1200 then 'PASS' else 'FAIL' end, msg);
      execute 'reset role';
      perform set_config('request.jwt.claim.sub', '', true);
      perform set_config('request.jwt.claims', '{"role":"anon"}', true);
      execute 'set local role anon';
      select count(*) into n from public.kt_products where id = msg;
      res := res || format('%s|A hidden product does not show on the website|%s visible', case when n = 0 then 'PASS' else 'FAIL' end, n);
      execute 'reset role';
      msg := null;
    end if;

    -- ---------- messages (update 28) ----------
    if to_regclass('public.ws_messages') is not null then
      select id into w_id from public.ws_workers where active limit 1;
      if w_id is not null then
        perform set_config('request.jwt.claim.sub', owner_id::text, true);
        perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        perform public.ws_owner_msg(w_id, 'TEST message');
        select count(*) into n from public.ws_messages where body = 'TEST message';
        res := res || format('%s|The owner can message a worker|%s sent', case when n = 1 then 'PASS' else 'FAIL' end, n);
        execute 'reset role';
        perform set_config('request.jwt.claim.sub', station_id::text, true);
        perform set_config('request.jwt.claims', json_build_object('sub', station_id, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        select count(*) into n from public.ws_messages;
        res := res || format('%s|The workshop computer cannot read all the messages|%s visible', case when n = 0 then 'PASS' else 'FAIL' end, n);
        begin
          perform public.ws_my_msgs('00000000-0000-0000-0000-000000000000'::uuid);
          res := res || 'FAIL|Messages need the worker to be signed in|they were shown'::text;
        exception when others then res := res || ('PASS|Messages need the worker to be signed in|' || sqlerrm); end;
        execute 'reset role';
        perform set_config('request.jwt.claim.sub', '', true);
        perform set_config('request.jwt.claims', '{"role":"anon"}', true);
        execute 'set local role anon';
        begin
          perform public.ws_owner_msg(w_id, 'hack');
          res := res || 'FAIL|A stranger cannot send messages|it was sent'::text;
        exception when others then res := res || ('PASS|A stranger cannot send messages|' || sqlerrm); end;
        execute 'reset role';
      end if;
    end if;

    -- ---------- fabrics (update 29) ----------
    if to_regclass('public.kt_fabrics') is not null then
      perform set_config('request.jwt.claim.sub', owner_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      declare fb uuid; begin
        fb := public.kt_save_fabric(jsonb_build_object('kind', 'TEST fabric', 'colour', 'Pink', 'hex', '#ff88aa', 'metres', 10));
        perform public.kt_fabric_metres(fb, -3);
        select count(*) into n from public.kt_fabrics where id = fb and metres = 7;
        res := res || format('%s|The owner can add a fabric and take metres off|%s right', case when n = 1 then 'PASS' else 'FAIL' end, n);
        perform public.kt_set_order_fabric(o_id, fb);
        select count(*) into n from public.ws_orders where id = o_id and fabric = 'TEST fabric · Pink';
        res := res || format('%s|An order can carry a fabric and colour|%s order', case when n = 1 then 'PASS' else 'FAIL' end, n);
        if exists (select 1 from information_schema.columns where table_name = 'kt_fabrics' and column_name = 'photo') then
          perform public.kt_save_fabric(jsonb_build_object('id', fb, 'kind', 'TEST fabric', 'colour', 'Pink', 'photo', 'https://example.com/f.jpg'));
          select count(*) into n from public.kt_fabrics where id = fb and photo = 'https://example.com/f.jpg';
          res := res || format('%s|A fabric can have a photo|%s saved', case when n = 1 then 'PASS' else 'FAIL' end, n);
          begin
            perform public.kt_save_fabric(jsonb_build_object('id', fb, 'kind', 'TEST fabric', 'colour', 'Pink', 'photo', 'javascript:alert(1)'));
            res := res || 'FAIL|A broken photo link is refused|it was saved'::text;
          exception when others then res := res || ('PASS|A broken photo link is refused|' || sqlerrm); end;
        end if;
        execute 'reset role';
        perform set_config('request.jwt.claim.sub', station_id::text, true);
        perform set_config('request.jwt.claims', json_build_object('sub', station_id, 'role', 'authenticated')::text, true);
        execute 'set local role authenticated';
        select count(*) into n from public.kt_fabrics where id = fb;
        res := res || format('%s|The workshop computer can see the fabric list|%s seen', case when n = 1 then 'PASS' else 'FAIL' end, n);
        begin
          perform public.kt_save_fabric(jsonb_build_object('kind', 'hack', 'colour', 'x'));
          res := res || 'FAIL|The workshop computer cannot change the fabric list|it was changed'::text;
        exception when others then res := res || ('PASS|The workshop computer cannot change the fabric list|' || sqlerrm); end;
        execute 'reset role';
        perform set_config('request.jwt.claim.sub', '', true);
        perform set_config('request.jwt.claims', '{"role":"anon"}', true);
        execute 'set local role anon';
        begin
          select count(*) into n from public.kt_fabrics;
          res := res || format('%s|A stranger cannot see the fabric list|%s seen', case when n = 0 then 'PASS' else 'FAIL' end, n);
        exception when others then res := res || ('PASS|A stranger cannot see the fabric list|' || sqlerrm); end;
        execute 'reset role';
      end;
    end if;

    -- ---------- several items in one order (update 31) ----------
    if exists (select 1 from information_schema.columns where table_name = 'ws_orders' and column_name = 'lines') then
      perform set_config('request.jwt.claim.sub', owner_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', owner_id, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      perform public.kt_set_order_lines(o_id, '[{"item":"Bar stools","qty":10},{"item":"Bar stools","qty":6},{"item":"Round tables","qty":2}]'::jsonb);
      select count(*) into n from public.ws_orders where id = o_id and qty = 18 and jsonb_array_length(lines) = 3 and item = 'Bar stools + Round tables';
      res := res || format('%s|One order can hold several items|%s right', case when n = 1 then 'PASS' else 'FAIL' end, n);
      perform public.kt_set_order_lines(o_id, '[{"item":"Test chairs","qty":3}]'::jsonb);
      select count(*) into n from public.ws_orders where id = o_id and qty = 3 and lines is null;
      res := res || format('%s|Going back to one item makes it a plain order again|%s right', case when n = 1 then 'PASS' else 'FAIL' end, n);
      begin
        perform public.kt_set_order_lines(o_id, '[{"item":"","qty":3}]'::jsonb);
        res := res || 'FAIL|An item with no name is refused|it was saved'::text;
      exception when others then res := res || ('PASS|An item with no name is refused|' || sqlerrm); end;
      execute 'reset role';
      perform set_config('request.jwt.claim.sub', station_id::text, true);
      perform set_config('request.jwt.claims', json_build_object('sub', station_id, 'role', 'authenticated')::text, true);
      execute 'set local role authenticated';
      begin
        perform public.kt_set_order_lines(o_id, '[{"item":"hack","qty":1}]'::jsonb);
        res := res || 'FAIL|The workshop computer cannot change items without the manager code|it was changed'::text;
      exception when others then res := res || ('PASS|The workshop computer cannot change items without the manager code|' || sqlerrm); end;
      execute 'reset role';
    end if;

    -- ---------- the client sees what she ordered (update 32) ----------
    if to_regprocedure('public.ws_room_order(text)') is not null then
      execute 'reset role';
      declare od jsonb; rc text := (select room_code from public.ws_orders where id = o_id); begin
        if rc is null then rc := 'testroom' || substr(md5(random()::text), 1, 6); update public.ws_orders set room_code = rc where id = o_id; end if;
        perform set_config('request.jwt.claim.sub', '', true);
        perform set_config('request.jwt.claims', '{"role":"anon"}', true);
        execute 'set local role anon';
        od := public.ws_room_order(rc);
        res := res || format('%s|The client sees her items with the order link|%s', case when od ? 'lines' and jsonb_array_length(od->'lines') >= 1 then 'PASS' else 'FAIL' end, coalesce(od->'lines'->0->>'item', 'nothing'));
        res := res || format('%s|The client never sees prices or workers|%s', case when od::text !~* 'price|total|worker|amount' then 'PASS' else 'FAIL' end, 'checked');
        od := public.ws_room_order('not-a-real-code');
        res := res || format('%s|A wrong link shows nothing|%s', case when od is null then 'PASS' else 'FAIL' end, coalesce(od::text, 'nothing'));
      end;
      begin
        perform public.kt_photo_to_room(1, 'design/x/y.jpg');
        res := res || 'FAIL|A stranger cannot move photos|it ran'::text;
      exception when others then res := res || ('PASS|A stranger cannot move photos|' || sqlerrm); end;
      execute 'reset role';
    end if;

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
