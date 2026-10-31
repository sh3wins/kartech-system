-- =====================================================================
--  UPDATE 18: invoice and payments, WITHOUT any money amounts
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Needs update-16 and update-17 first.
--
--  How it works:
--   • The owner makes the invoice as usual and sends it on WhatsApp.
--     The app only remembers THAT it was sent, never the amounts.
--   • New orders wait ("on hold") until the owner confirms the half
--     payment. The workshop does not get them before that.
--   • The client taps "I've paid half" in their Order Room and types the
--     M-Pesa code. The owner checks M-Pesa and taps "Half payment received".
--   • Before delivery: the same for the rest. "Delivered" stays locked
--     until the order is fully paid.
--   • Workers only ever see "Deposit confirmed".
-- =====================================================================

-- ---------- the order remembers the payment steps (no amounts) ----------
alter table public.ws_orders add column if not exists on_hold        boolean not null default false;
alter table public.ws_orders add column if not exists invoice_at     timestamptz;
alter table public.ws_orders add column if not exists dep_code       text;
alter table public.ws_orders add column if not exists dep_claimed_at timestamptz;
alter table public.ws_orders add column if not exists dep_ok_at      timestamptz;
alter table public.ws_orders add column if not exists bal_code       text;
alter table public.ws_orders add column if not exists bal_claimed_at timestamptz;
alter table public.ws_orders add column if not exists paid_at        timestamptz;
-- orders that already exist keep going; every NEW order waits for the half payment
alter table public.ws_orders alter column on_hold set default true;

create or replace function public.ws_held(p_order uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select on_hold from public.ws_orders where id = p_order), false);
$$;

-- ---------- where the client sends money (a phone number and a name) ----------
create or replace function public.ws_pay_settings() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  return jsonb_build_object(
    'phone', (select value from public.ws_settings where key = 'pay_phone'),
    'name',  (select value from public.ws_settings where key = 'pay_name'));
end $$;

create or replace function public.ws_set_pay(p_phone text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare ph text := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');
begin
  perform public.ws_need_owner();
  if ph !~ '^(\+?254|0)[17][0-9]{8}$' then raise exception 'Type the M-Pesa number like 0712 345 678'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'Type the name M-Pesa shows for that number'; end if;
  insert into public.ws_settings (key, value) values ('pay_phone', ph) on conflict (key) do update set value = excluded.value, updated_at = now();
  insert into public.ws_settings (key, value) values ('pay_name', left(trim(p_name), 60)) on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

-- ---------- the workshop skips orders that are waiting for the half payment ----------
create or replace function public.ws_release(p_stage text) returns void
language plpgsql security definer set search_path = public as $$
declare w record; tid uuid; o public.ws_orders; jt public.ws_tasks; mate text;
begin
  for w in select wk.* from public.ws_workers wk
            where public.ws_is_here(wk) and wk.task_id is null
              and (wk.stage = p_stage
                   or exists (select 1 from public.ws_tasks q where q.stage = p_stage and q.status in ('queued','assigned','working') and wk.id = any(q.planned) and not public.ws_held(q.order_id))
                   or (p_stage = any(wk.covers)
                       and not exists (select 1 from public.ws_tasks q where q.stage = wk.stage and q.status = 'queued' and not public.ws_held(q.order_id))))
            order by exists (select 1 from public.ws_tasks q where q.stage = p_stage and q.status in ('queued','assigned','working') and wk.id = any(q.planned) and not public.ws_held(q.order_id)) desc,
                     (wk.stage = p_stage) desc, wk.arrived_at nulls last, wk.created_at loop
    -- 1. picked to help on a job someone already has → join them
    jt := null;
    select * into jt from public.ws_tasks q
     where q.stage = p_stage and q.status in ('assigned','working') and w.id = any(q.planned) and q.worker_id is distinct from w.id
     order by q.rank limit 1;
    if jt.id is not null then
      mate := public.ws_task_names(jt.id);
      update public.ws_workers set task_id = jt.id, waiting_logged = false where id = w.id;
      select * into o from public.ws_orders where id = jt.order_id;
      perform public.ws_note('info', w.name || ' joined ' || coalesce(mate, 'the job') || ' on ' || o.ref || ' · ' || public.ws_stage_name(p_stage), o.id);
      continue;
    end if;
    -- 2. next job in line (never one that is waiting for the half payment)
    tid := null;
    select q.id into tid from public.ws_tasks q
     where q.stage = p_stage and q.status = 'queued' and not public.ws_held(q.order_id)
       and (w.id = any(q.planned)
            or ((w.stage = p_stage or p_stage = any(w.covers))
                and not exists (select 1 from public.ws_workers pw where pw.id = any(q.planned) and public.ws_is_here(pw))))
     order by (w.id = any(q.planned)) desc, q.rank limit 1 for update skip locked;
    if tid is null then
      if w.stage = p_stage and not w.waiting_logged
         and not exists (select 1 from public.ws_tasks q where q.stage = p_stage and q.status = 'queued' and not public.ws_held(q.order_id)) then
        perform public.ws_note('warn', w.name || ' (' || public.ws_stage_name(p_stage) || ') has no work waiting');
        update public.ws_workers set waiting_logged = true where id = w.id;
      end if;
      continue;
    end if;
    update public.ws_tasks set status = 'assigned', worker_id = w.id, assigned_at = now() where id = tid;
    update public.ws_workers set task_id = tid, waiting_logged = false where id = w.id;
    select o2.* into o from public.ws_orders o2 join public.ws_tasks t on t.order_id = o2.id where t.id = tid;
    perform public.ws_note('info', w.name || ' got the next job: ' || o.ref || ' · ' || public.ws_stage_name(p_stage)
      || case when w.stage <> p_stage and not exists (select 1 from public.ws_tasks where id = tid and w.id = any(planned)) then ' (covering)' else '' end, o.id);
  end loop;
end $$;

-- giving a held job by hand is blocked too
create or replace function public.ws_give_task(p_task uuid, p_worker uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t public.ws_tasks; w public.ws_workers; o public.ws_orders; busy text;
begin
  perform public.ws_need_owner();
  select * into t from public.ws_tasks where id = p_task for update;
  if t.id is null or t.status = 'done' then raise exception 'This step is already finished'; end if;
  if t.status = 'waiting' then raise exception 'This step is not ready yet. The step before it is not finished.'; end if;
  if public.ws_held(t.order_id) and t.status = 'queued' then
    raise exception 'This order is waiting for the half payment. Confirm the payment (or tap "Start without payment") first.';
  end if;
  select * into w from public.ws_workers where id = p_worker for update;
  if w.id is null or not public.ws_is_here(w) then raise exception 'That worker is away or switched off'; end if;
  if t.worker_id = w.id then return; end if;
  if w.task_id is not null then
    select o2.ref into busy from public.ws_tasks x join public.ws_orders o2 on o2.id = x.order_id where x.id = w.task_id;
    raise exception '% is busy on %. Wait until they finish, or mark them away.', w.name, coalesce(busy, 'another job');
  end if;
  if t.worker_id is not null then
    update public.ws_workers set task_id = null where id = t.worker_id;
  end if;
  update public.ws_tasks set status = 'assigned', worker_id = w.id, assigned_at = now(), started_at = null where id = t.id;
  update public.ws_workers set task_id = t.id, waiting_logged = false where id = w.id;
  select * into o from public.ws_orders where id = t.order_id;
  perform public.ws_note('info', 'Owner gave ' || o.ref || ' · ' || public.ws_stage_name(t.stage) || ' to ' || w.name, o.id);
  perform public.ws_release_all();
end $$;

-- "Delivered" only when fully paid
create or replace function public.ws_deliver(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  if exists (select 1 from public.ws_tasks where order_id = p_order and status <> 'done') then raise exception 'This order is not finished yet'; end if;
  if (select paid_at from public.ws_orders where id = p_order) is null then
    raise exception 'The balance is not paid yet. Confirm "Fully paid" first, then mark it delivered.';
  end if;
  update public.ws_orders set delivered_at = now() where id = p_order returning * into o;
  perform public.ws_note('good', o.ref || ' delivered to ' || o.customer, o.id);
  perform public.ws_sync_source(o.source_order_id);
end $$;

-- ---------- owner: the payment steps ----------
create or replace function public.ws_invoice_sent(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  update public.ws_orders set invoice_at = coalesce(invoice_at, now()) where id = p_order returning * into o;
  if o.id is null then raise exception 'Order not found'; end if;
  if not exists (select 1 from public.ws_room_msgs where order_id = o.id and who = 'kartech' and text like '📄%') then
    insert into public.ws_room_msgs (order_id, who, text)
    values (o.id, 'kartech', '📄 We sent your invoice on WhatsApp. To start, pay half and tap "I''ve paid half" in Payment above.');
  end if;
end $$;

create or replace function public.ws_hold(p_order uuid, p_hold boolean) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  if p_hold and exists (select 1 from public.ws_tasks where order_id = p_order and status in ('assigned','working','done')) then
    raise exception 'Work on this order has already started, so it cannot wait any more.';
  end if;
  update public.ws_orders set on_hold = p_hold where id = p_order returning * into o;
  if not p_hold then
    perform public.ws_note('info', o.ref || ' can start now', o.id);
    perform public.ws_release_all();
  end if;
end $$;

-- p_part: 'half' or 'full'
create or replace function public.ws_pay_ok(p_order uuid, p_part text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; was_held boolean;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order for update;
  if o.id is null then raise exception 'Order not found'; end if;
  was_held := o.on_hold;
  if p_part = 'half' then
    if o.dep_ok_at is not null then return; end if;
    update public.ws_orders set dep_ok_at = now(), on_hold = false where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'kartech',
      case when was_held then '✓ Half payment received. Thank you! Your order is now in the workshop.' else '✓ Half payment received. Thank you!' end);
    perform public.ws_note('good', o.ref || ' · deposit confirmed' || case when was_held then ', the workshop can start' else '' end, o.id);
  elsif p_part = 'full' then
    if o.paid_at is not null then return; end if;
    update public.ws_orders set paid_at = now(), dep_ok_at = coalesce(dep_ok_at, now()), on_hold = false where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'kartech', '✓ Fully paid. Thank you! We will let you know the delivery day.');
    perform public.ws_note('good', o.ref || ' · fully paid' || case when was_held then ', the workshop can start' else '' end, o.id);
  else
    raise exception 'Unknown payment step';
  end if;
  if was_held then perform public.ws_release_all(); end if;
end $$;

-- the client's code could not be found in M-Pesa
create or replace function public.ws_pay_not_found(p_order uuid, p_part text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; code text;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order;
  if o.id is null then raise exception 'Order not found'; end if;
  code := case when p_part = 'half' then o.dep_code else o.bal_code end;
  if p_part = 'half' then update public.ws_orders set dep_code = null, dep_claimed_at = null where id = o.id;
  else update public.ws_orders set bal_code = null, bal_claimed_at = null where id = o.id; end if;
  insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'kartech',
    'We could not find your payment' || coalesce(' (code ' || code || ')', '') || ' yet. Please check the M-Pesa code and tap "I''ve paid" again, or call us.');
end $$;

-- tapped "received" by mistake
create or replace function public.ws_pay_undo(p_order uuid, p_part text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  if p_part = 'half' then update public.ws_orders set dep_ok_at = null where id = p_order and paid_at is null;
  else update public.ws_orders set paid_at = null where id = p_order and delivered_at is null; end if;
end $$;

-- ---------- the client: "I've paid" + M-Pesa code ----------
create or replace function public.ws_room_paid(p_code text, p_part text, p_txn text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; c text := upper(regexp_replace(coalesce(p_txn, ''), '[^A-Za-z0-9]', '', 'g')); first text;
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then raise exception 'Order not found'; end if;
  if c !~ '^[A-Z0-9]{8,12}$' then raise exception 'Type the M-Pesa code from your SMS, e.g. SJK7XQ2M4P'; end if;
  if o.invoice_at is null then raise exception 'Kartech has not sent the invoice yet.'; end if;
  if (select count(*) from public.ws_room_msgs where order_id = o.id and who = 'customer' and text like '💳%' and at > now() - interval '1 hour') >= 6 then
    raise exception 'Please wait a little before trying again.';
  end if;
  first := split_part(trim(o.customer), ' ', 1);
  if p_part = 'half' then
    if o.dep_ok_at is not null then raise exception 'Your half payment is already confirmed.'; end if;
    update public.ws_orders set dep_code = c, dep_claimed_at = now() where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'customer', '💳 I''ve paid half · M-Pesa code ' || c);
    perform public.ws_note('alert', first || ' says the half payment for ' || o.ref || ' is sent · M-Pesa code ' || c || '. Check it and confirm.', o.id);
  elsif p_part = 'full' then
    if o.paid_at is not null then raise exception 'Your order is already fully paid.'; end if;
    update public.ws_orders set bal_code = c, bal_claimed_at = now() where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'customer',
      case when o.dep_ok_at is null then '💳 I''ve paid it all · M-Pesa code ' else '💳 I''ve paid the balance · M-Pesa code ' end || c);
    perform public.ws_note('alert', first || ' says ' || case when o.dep_ok_at is null then 'the full payment' else 'the balance' end || ' for ' || o.ref || ' is sent · M-Pesa code ' || c || '. Check it and confirm.', o.id);
  else
    raise exception 'Unknown payment step';
  end if;
end $$;

-- the client's Order Room now includes the payment steps (still no amounts)
create or replace function public.ws_room(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.ws_orders;
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then return null; end if;
  return jsonb_build_object(
    'ref', o.ref, 'item', o.item, 'qty', o.qty, 'name', split_part(trim(o.customer), ' ', 1),
    'deadline', o.deadline, 'delivered', o.delivered_at is not null, 'approved_at', o.approved_at,
    'notes', o.notes, 'delivery_on', o.delivery_on,
    'pay', case when o.invoice_at is null and o.dep_ok_at is null and o.paid_at is null then null else jsonb_build_object(
      'invoice', o.invoice_at is not null,
      'phone', (select value from public.ws_settings where key = 'pay_phone'),
      'to',    (select value from public.ws_settings where key = 'pay_name'),
      'dep_claimed', o.dep_claimed_at is not null, 'dep_code', o.dep_code, 'dep_ok', o.dep_ok_at,
      'bal_claimed', o.bal_claimed_at is not null, 'bal_code', o.bal_code, 'paid', o.paid_at,
      'hold', o.on_hold) end,
    'steps', (select coalesce(jsonb_agg(jsonb_build_object('name', g.grp, 'status', g.st) order by g.first_step), '[]'::jsonb)
                from (select public.ws_step_group(t.stage) grp, min(t.step) first_step,
                             case when bool_and(t.status = 'done') then 'done'
                                  when bool_or(t.status in ('working', 'assigned', 'done')) then 'working' else 'waiting' end st
                        from public.ws_tasks t where t.order_id = o.id group by 1) g),
    'photos', (select coalesce(jsonb_agg(jsonb_build_object('path', p.path, 'at', p.at) order by p.id), '[]'::jsonb)
                 from public.ws_photos p where p.order_id = o.id and p.bucket = 'room-files'),
    'msgs', (select coalesce(jsonb_agg(jsonb_build_object('who', m.who, 'text', m.text, 'at', m.at) order by m.id), '[]'::jsonb)
               from (select * from public.ws_room_msgs where order_id = o.id order by id desc limit 100) m));
end $$;

-- the worker's job card: only "Deposit confirmed", never anything else about money
create or replace function public.ws_my_job(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; t public.ws_tasks; o public.ws_orders; nxt record; after_stage text; mates text;
begin
  w := public.ws_me(p_token);
  if w.task_id is not null then
    select * into t from public.ws_tasks where id = w.task_id;
    select * into o from public.ws_orders where id = t.order_id;
    after_stage := o.stages[t.step + 1];
    select string_agg(name, ' & ' order by name) into mates from public.ws_workers where task_id = t.id and id <> w.id;
  end if;
  select o2.ref, o2.qty, o2.item into nxt from public.ws_tasks q join public.ws_orders o2 on o2.id = q.order_id
   where q.stage = w.stage and q.status = 'queued' and not o2.on_hold order by q.rank limit 1;
  return jsonb_build_object(
    'worker', jsonb_build_object('name', w.name, 'stage', w.stage),
    'task', case when t.id is null then null else jsonb_build_object(
      'status', t.status, 'stage', t.stage, 'problem_reason', t.problem_reason, 'problem_stopped', t.problem_stopped,
      'problem_ack', t.problem_ack_at is not null, 'with', mates, 'approved', o.approved_at, 'deposit', o.dep_ok_at is not null) end,
    'order', case when o.id is null then null else jsonb_build_object(
      'ref', o.ref, 'item', o.item, 'qty', o.qty, 'deadline', o.deadline, 'urgency', o.urgency, 'notes', o.notes) end,
    'after', after_stage,
    'next', case when nxt.ref is null then null else jsonb_build_object('ref', nxt.ref, 'qty', nxt.qty, 'item', nxt.item) end);
end $$;

-- the manager's client list says when an order is waiting for the deposit (nothing else)
create or replace function public.ws_foreman_rooms(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_foreman_ok(p_pin);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'ref', o.ref, 'customer', o.customer, 'item', o.item, 'qty', o.qty,
             'notes', o.notes, 'room', o.room_code, 'approved', o.approved_at, 'at', o.created_at,
             'hold', o.on_hold)
           order by o.created_at desc)
    from (select * from public.ws_orders
          where delivered_at is null and room_code is not null
          order by created_at desc limit 80) o
  ), '[]'::jsonb);
end $$;

-- ---------- who may use what ----------
revoke all on function public.ws_pay_settings(), public.ws_set_pay(text, text), public.ws_invoice_sent(uuid),
  public.ws_hold(uuid, boolean), public.ws_pay_ok(uuid, text), public.ws_pay_not_found(uuid, text),
  public.ws_pay_undo(uuid, text), public.ws_held(uuid) from public, anon;
grant execute on function public.ws_pay_settings(), public.ws_set_pay(text, text), public.ws_invoice_sent(uuid),
  public.ws_hold(uuid, boolean), public.ws_pay_ok(uuid, text), public.ws_pay_not_found(uuid, text),
  public.ws_pay_undo(uuid, text), public.ws_held(uuid) to authenticated;
grant execute on function public.ws_room_paid(text, text, text) to anon, authenticated;
grant execute on function public.ws_room(text) to anon, authenticated;
