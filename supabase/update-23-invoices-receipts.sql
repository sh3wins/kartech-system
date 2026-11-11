-- =====================================================================
--  UPDATE 23: invoices and official receipts (with amounts)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Needs updates 1–22 first.
--
--  • Only the OWNER can see or create invoices, payments and receipts.
--    The manager, the workshop screen and workers can never read them
--    (the database refuses, not just the screen).
--  • Any payment the owner confirms starts the workshop.
--  • When the balance reaches 0 the order counts as fully paid and
--    "Delivered" unlocks.
--  • Each invoice/receipt has a secret check code for the QR on the PDF,
--    so anyone holding the PDF can check it is genuine.
-- =====================================================================

-- ---------- numbering: INV-2026-0001, RCT-2026-0001 ----------
create table if not exists public.kt_counters (key text primary key, n int not null default 0);
alter table public.kt_counters enable row level security;

create or replace function public.kt_next_no(p_prefix text) returns text
language plpgsql security definer set search_path = public as $$
declare k text := p_prefix || '-' || to_char(now() at time zone 'Africa/Nairobi', 'YYYY'); v int;
begin
  insert into public.kt_counters (key, n) values (k, 1)
  on conflict (key) do update set n = kt_counters.n + 1 returning n into v;
  return k || '-' || lpad(v::text, 4, '0');
end $$;

-- ---------- invoices and payments ----------
create table if not exists public.kt_invoices (
  id          uuid primary key default gen_random_uuid(),
  no          text unique not null,
  order_id    uuid references public.ws_orders(id) on delete set null,
  order_ref   text,
  customer    text not null,
  phone       text,
  items       jsonb not null,                -- [{ "desc": "...", "qty": 6, "price": 4500 }]
  total       numeric(12,2) not null check (total > 0),
  due_date    date,
  check_code  text unique not null default public.ws_new_code(),
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create table if not exists public.kt_payments (
  id          uuid primary key default gen_random_uuid(),
  no          text unique not null,
  invoice_id  uuid not null references public.kt_invoices(id) on delete cascade,
  amount      numeric(12,2) not null check (amount > 0),
  method      text not null check (method in ('M-Pesa','Cash','Bank','Other')),
  reference   text,
  check_code  text unique not null default public.ws_new_code(),
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
create index if not exists kt_invoices_order on public.kt_invoices(order_id);
create index if not exists kt_payments_invoice on public.kt_payments(invoice_id);

alter table public.kt_invoices enable row level security;
alter table public.kt_payments enable row level security;
drop policy if exists "owner reads invoices" on public.kt_invoices;
drop policy if exists "owner reads payments" on public.kt_payments;
create policy "owner reads invoices" on public.kt_invoices for select to authenticated using (public.is_admin());
create policy "owner reads payments" on public.kt_payments for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.kt_invoices, public.kt_payments, public.kt_counters from anon, authenticated;
revoke all on public.kt_invoices, public.kt_payments, public.kt_counters from anon;

create or replace function public.kt_paid(p_invoice uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount), 0) from public.kt_payments where invoice_id = p_invoice;
$$;

-- ---------- business details printed on the PDFs ----------
create or replace function public.kt_business() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  return jsonb_build_object(
    'phone',   coalesce((select value from public.ws_settings where key = 'biz_phone'), (select value from public.ws_settings where key = 'pay_phone')),
    'address', coalesce((select value from public.ws_settings where key = 'biz_address'), 'Outer Ring Road, Umoja (Mtindwa), Nairobi'),
    'kra',     (select value from public.ws_settings where key = 'biz_kra'),
    'pay_phone', (select value from public.ws_settings where key = 'pay_phone'),
    'pay_name',  (select value from public.ws_settings where key = 'pay_name'));
end $$;

create or replace function public.kt_set_business(p_phone text, p_address text, p_kra text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  insert into public.ws_settings (key, value) values ('biz_phone', left(trim(coalesce(p_phone, '')), 30)) on conflict (key) do update set value = excluded.value, updated_at = now();
  insert into public.ws_settings (key, value) values ('biz_address', left(trim(coalesce(p_address, '')), 120)) on conflict (key) do update set value = excluded.value, updated_at = now();
  insert into public.ws_settings (key, value) values ('biz_kra', upper(left(trim(coalesce(p_kra, '')), 20))) on conflict (key) do update set value = excluded.value, updated_at = now();
end $$;

-- ---------- owner: make or change the invoice for an order ----------
create or replace function public.kt_save_invoice(p_order uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; inv public.kt_invoices; it jsonb; tot numeric(12,2) := 0; clean jsonb := '[]'::jsonb;
        q numeric; pr numeric; d text;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order;
  if o.id is null then raise exception 'Order not found'; end if;
  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    d := left(trim(coalesce(it->>'desc', '')), 200);
    q := nullif(it->>'qty', '')::numeric; pr := nullif(it->>'price', '')::numeric;
    if d = '' and q is null and pr is null then continue; end if;
    if d = '' then raise exception 'Every line needs a description'; end if;
    if q is null or q <= 0 or q <> trunc(q) then raise exception 'Quantity must be a whole number, 1 or more'; end if;
    if pr is null or pr < 0 then raise exception 'Type the price for "%"', d; end if;
    clean := clean || jsonb_build_array(jsonb_build_object('desc', d, 'qty', q, 'price', round(pr, 2)));
    tot := tot + round(q * pr, 2);
  end loop;
  if jsonb_array_length(clean) = 0 then raise exception 'Add at least one line with a price'; end if;
  if tot <= 0 then raise exception 'The total must be more than 0'; end if;

  select * into inv from public.kt_invoices where order_id = o.id order by created_at desc limit 1;
  if inv.id is null then
    insert into public.kt_invoices (no, order_id, order_ref, customer, phone, items, total, due_date)
    values (public.kt_next_no('INV'), o.id, o.ref, o.customer, nullif(trim(coalesce(p->>'phone', '')), ''), clean, tot, nullif(p->>'due_date', '')::date)
    returning * into inv;
  else
    if tot < public.kt_paid(inv.id) then raise exception 'The new total is less than what is already paid'; end if;
    update public.kt_invoices set items = clean, total = tot, phone = nullif(trim(coalesce(p->>'phone', '')), ''),
      due_date = nullif(p->>'due_date', '')::date, customer = o.customer where id = inv.id returning * into inv;
    -- a bigger total can re-open "fully paid"
    if public.kt_paid(inv.id) < inv.total and o.paid_at is not null and o.delivered_at is null then
      update public.ws_orders set paid_at = null where id = o.id;
    end if;
  end if;
  return to_jsonb(inv);
end $$;

-- the invoice PDF was sent → the client's Order Room shows "pay to start" (no amounts there)
create or replace function public.kt_invoice_sent(p_invoice uuid) returns void
language plpgsql security definer set search_path = public as $$
declare inv public.kt_invoices;
begin
  perform public.ws_need_owner();
  update public.kt_invoices set sent_at = coalesce(sent_at, now()) where id = p_invoice returning * into inv;
  if inv.order_id is not null then perform public.ws_invoice_sent(inv.order_id); end if;
end $$;

-- ---------- owner: record a payment she has checked → receipt ----------
create or replace function public.kt_record_payment(p_invoice uuid, p_amount numeric, p_method text, p_reference text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare inv public.kt_invoices; o public.ws_orders; pay public.kt_payments; bal numeric; ref text := upper(trim(coalesce(p_reference, '')));
        first_pay boolean;
begin
  perform public.ws_need_owner();
  select * into inv from public.kt_invoices where id = p_invoice for update;
  if inv.id is null then raise exception 'Invoice not found'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Type the amount received'; end if;
  bal := inv.total - public.kt_paid(inv.id);
  if bal <= 0 then raise exception 'This invoice is already fully paid'; end if;
  if round(p_amount, 2) > bal then raise exception 'That is more than the balance (KSh %)', to_char(bal, 'FM999,999,990.00'); end if;
  if p_method not in ('M-Pesa','Cash','Bank','Other') then raise exception 'Pick how it was paid'; end if;
  if p_method in ('M-Pesa','Bank') and length(ref) < 6 then raise exception 'Type the % code from the message', p_method; end if;
  if ref <> '' and exists (select 1 from public.kt_payments where upper(reference) = ref) then
    raise exception 'The code % is already on another receipt', ref;
  end if;
  first_pay := not exists (select 1 from public.kt_payments where invoice_id = inv.id);
  insert into public.kt_payments (no, invoice_id, amount, method, reference)
  values (public.kt_next_no('RCT'), inv.id, round(p_amount, 2), p_method, nullif(ref, ''))
  returning * into pay;
  bal := inv.total - public.kt_paid(inv.id);

  -- the order moves on by itself (workers only ever see "Deposit confirmed")
  if inv.order_id is not null then
    select * into o from public.ws_orders where id = inv.order_id;
    if o.invoice_at is null then update public.ws_orders set invoice_at = now() where id = o.id; end if;
    update public.ws_orders set dep_claimed_at = null, dep_code = null where id = o.id and dep_claimed_at is not null;
    if bal <= 0 then
      update public.ws_orders set bal_claimed_at = null, bal_code = null where id = o.id;
      perform public.ws_pay_ok(o.id, 'full');
    elsif o.dep_ok_at is null then
      perform public.ws_pay_ok(o.id, 'half');
    else
      update public.ws_orders set bal_claimed_at = null, bal_code = null where id = o.id;
      insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'kartech', '✓ Payment received. Thank you! Your receipt is on WhatsApp.');
    end if;
  end if;
  return jsonb_build_object('payment', to_jsonb(pay), 'paid', public.kt_paid(inv.id), 'balance', bal, 'first', first_pay);
end $$;

create or replace function public.kt_receipt_sent(p_payment uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  update public.kt_payments set sent_at = coalesce(sent_at, now()) where id = p_payment;
end $$;

-- typed the wrong amount? remove the LAST receipt of an invoice (same day only)
create or replace function public.kt_cancel_payment(p_payment uuid) returns void
language plpgsql security definer set search_path = public as $$
declare pay public.kt_payments; inv public.kt_invoices; o public.ws_orders;
begin
  perform public.ws_need_owner();
  select * into pay from public.kt_payments where id = p_payment;
  if pay.id is null then return; end if;
  if exists (select 1 from public.kt_payments where invoice_id = pay.invoice_id and created_at > pay.created_at) then
    raise exception 'Only the latest receipt can be cancelled';
  end if;
  if (pay.created_at at time zone 'Africa/Nairobi')::date <> (now() at time zone 'Africa/Nairobi')::date then
    raise exception 'Only a receipt made today can be cancelled';
  end if;
  select * into inv from public.kt_invoices where id = pay.invoice_id;
  delete from public.kt_payments where id = pay.id;
  if inv.order_id is not null then
    select * into o from public.ws_orders where id = inv.order_id;
    if o.delivered_at is null then
      update public.ws_orders set paid_at = null where id = o.id;
      if not exists (select 1 from public.kt_payments where invoice_id = inv.id) then
        update public.ws_orders set dep_ok_at = null where id = o.id;
      end if;
    end if;
  end if;
  perform public.ws_note('warn', 'Receipt ' || pay.no || ' cancelled' || coalesce(' (' || inv.order_ref || ')', ''), inv.order_id);
end $$;

-- ---------- the QR on a PDF: anyone holding it can check it is genuine ----------
create or replace function public.kt_check(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare inv public.kt_invoices; pay public.kt_payments;
begin
  select * into pay from public.kt_payments where check_code = lower(trim(p_code));
  if pay.id is not null then
    select * into inv from public.kt_invoices where id = pay.invoice_id;
    return jsonb_build_object('type', 'receipt', 'no', pay.no, 'at', pay.created_at, 'amount', pay.amount, 'method', pay.method,
      'customer', split_part(trim(inv.customer), ' ', 1), 'order', inv.order_ref, 'invoice', inv.no);
  end if;
  select * into inv from public.kt_invoices where check_code = lower(trim(p_code));
  if inv.id is not null then
    return jsonb_build_object('type', 'invoice', 'no', inv.no, 'at', inv.created_at, 'amount', inv.total,
      'customer', split_part(trim(inv.customer), ' ', 1), 'order', inv.order_ref);
  end if;
  return null;
end $$;

-- ---------- payment wording now that ANY payment starts the work ----------
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
      case when was_held then '✓ Payment received. Thank you! Your order is now in the workshop.' else '✓ Payment received. Thank you!' end);
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

-- the Order Room note when the invoice goes out (no amounts there)
create or replace function public.ws_invoice_sent(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_need_owner();
  update public.ws_orders set invoice_at = coalesce(invoice_at, now()) where id = p_order returning * into o;
  if o.id is null then raise exception 'Order not found'; end if;
  if not exists (select 1 from public.ws_room_msgs where order_id = o.id and who = 'kartech' and text like '📄%') then
    insert into public.ws_room_msgs (order_id, who, text)
    values (o.id, 'kartech', '📄 We sent your invoice on WhatsApp. When you have paid, tap "I''ve paid" at the top of this page.');
  end if;
end $$;

-- the client's "I've paid" button: same as before, new words (any payment starts the work)
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
    if o.dep_ok_at is not null then raise exception 'Your deposit is already confirmed.'; end if;
    update public.ws_orders set dep_code = c, dep_claimed_at = now() where id = o.id;
    insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'customer', '💳 I''ve paid the deposit · M-Pesa code ' || c);
    perform public.ws_note('alert', first || ' says the deposit for ' || o.ref || ' is sent · M-Pesa code ' || c || '. Check it and confirm.', o.id);
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

-- ---------- who may use what ----------
revoke all on function public.kt_next_no(text), public.kt_paid(uuid) from public, anon, authenticated;
revoke all on function public.kt_business(), public.kt_set_business(text, text, text), public.kt_save_invoice(uuid, jsonb),
  public.kt_invoice_sent(uuid), public.kt_record_payment(uuid, numeric, text, text), public.kt_receipt_sent(uuid),
  public.kt_cancel_payment(uuid) from public, anon;
grant execute on function public.kt_business(), public.kt_set_business(text, text, text), public.kt_save_invoice(uuid, jsonb),
  public.kt_invoice_sent(uuid), public.kt_record_payment(uuid, numeric, text, text), public.kt_receipt_sent(uuid),
  public.kt_cancel_payment(uuid) to authenticated;
grant execute on function public.kt_check(text) to anon, authenticated;
grant select on public.kt_invoices, public.kt_payments to authenticated;
