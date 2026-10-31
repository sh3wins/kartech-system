-- =====================================================================
--  KARTECH: updates 14 to 18 in ONE go (pictures, sales, Order Room,
--  client links, payments). Paste ALL of this into Supabase → SQL Editor
--  → New query → Run. Safe to run again, even if some were run before.
-- =====================================================================

-- >>>>>>>>>> update-14-order-pictures.sql
-- =====================================================================
--  KARTECH UPDATE 14: pictures of what to make (workers see them)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-12-all.sql first.
--
--  • Each order can have pictures of WHAT TO MAKE: the customer's sample,
--    a sketch, a fabric colour. Workers see them on their job card, so
--    nothing depends on word of mouth.
--  • "Finished work" photos stay private to the owner, like before.
-- =====================================================================

alter table public.ws_photos add column if not exists kind text not null default 'done';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'ws_photos_kind_check') then
    alter table public.ws_photos add constraint ws_photos_kind_check check (kind in ('ref', 'done'));
  end if;
end $$;

-- the owner sees all photos; the workshop computer sees only "what to make" pictures
drop policy if exists "owner reads photos" on public.ws_photos;
create policy "owner reads photos" on public.ws_photos for select to authenticated
  using (public.is_admin() or (kind = 'ref' and public.ws_is_station()));

create or replace function public.ws_add_photo(p_order uuid, p_path text, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; k text := case when p_kind = 'ref' then 'ref' else 'done' end;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order;
  if o.id is null then raise exception 'Order not found'; end if;
  if p_path is null or p_path not like o.id::text || '/%' then raise exception 'Bad photo'; end if;
  insert into public.ws_photos (order_id, path, kind) values (o.id, p_path, k);
  perform public.ws_note('good', case when k = 'ref' then 'Picture of what to make added to ' else 'Photo of finished work added to ' end || o.ref, o.id);
end $$;

-- the worker's job card: pictures for the order they are working on
create or replace function public.ws_job_pictures(p_token uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare w public.ws_workers;
begin
  w := public.ws_me(p_token);
  return coalesce((select array_agg(p.path order by p.id) from public.ws_photos p join public.ws_tasks t on t.order_id = p.order_id
                    where t.id = w.task_id and p.kind = 'ref'), '{}');
end $$;

revoke all on function public.ws_add_photo(uuid, text, text), public.ws_job_pictures(uuid) from public, anon;
grant execute on function public.ws_add_photo(uuid, text, text) to authenticated;
grant execute on function public.ws_job_pictures(uuid)          to authenticated;

-- the workshop computer may open "what to make" pictures (never finished-work photos)
do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    drop policy if exists "kartech photos workshop read" on storage.objects;
    create policy "kartech photos workshop read" on storage.objects for select to authenticated
      using (bucket_id = 'kartech-photos' and public.ws_is_station()
             and exists (select 1 from public.ws_photos p where p.path = storage.objects.name and p.kind = 'ref'));
  end if;
end $do$;

-- >>>>>>>>>> update-15-sales.sql
-- =====================================================================
--  KARTECH UPDATE 15: the manager takes sales + quote requests in the app
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-14-order-pictures.sql first.
--
--  • When the owner is away, the manager adds orders on the workshop
--    screen (Manager → New order), with pictures. The owner is told.
--  • "Get a quote" requests from the website show in the owner app with
--    the customer's photos. One tap turns a request into an order and the
--    photos become "What to make" pictures for the workers.
-- =====================================================================

alter table public.ws_orders add column if not exists created_by text not null default 'owner';
alter table public.ws_orders add column if not exists request_id uuid;
alter table public.ws_photos add column if not exists bucket text not null default 'kartech-photos';

-- ---------- one place that creates orders (owner or manager) ----------
create or replace function public.ws_new_order(p jsonb, p_by text) returns text
language plpgsql security definer set search_path = public as $$
declare o_id uuid; v_ref text; st text[]; i int; t_id uuid; r public.custom_requests; f text;
begin
  select array_agg(s.id order by s.sort) into st
    from public.ws_steps s where s.active and s.id in (select jsonb_array_elements_text(p->'stages'));
  if st is null or array_length(st, 1) is null then raise exception 'Pick at least one step'; end if;
  if length(trim(coalesce(p->>'customer',''))) = 0 or length(trim(coalesce(p->>'item',''))) = 0 then raise exception 'Customer and item are required'; end if;
  v_ref := 'KT-' || nextval('public.ws_ref_seq');
  insert into public.ws_orders (ref, customer, item, qty, deadline, urgency, notes, stages, created_by, request_id)
  values (v_ref, left(trim(p->>'customer'), 120), left(trim(p->>'item'), 120), greatest(1, coalesce((p->>'qty')::int, 1)),
          coalesce((p->>'deadline')::date, current_date + 7),
          case when p->>'urgency' in ('urgent','high','normal') then p->>'urgency' else 'normal' end,
          nullif(left(trim(coalesce(p->>'notes','')), 500), ''), st, p_by, nullif(p->>'request_id', '')::uuid)
  returning id into o_id;
  for i in 1 .. array_length(st, 1) loop
    insert into public.ws_tasks (order_id, step, stage) values (o_id, i, st[i]) returning id into t_id;
  end loop;
  perform public.ws_set_planned(o_id, p->'people');
  perform public.ws_set_together(o_id, p->'together');

  -- from a website quote request: its photos become "what to make" pictures
  if nullif(p->>'request_id', '') is not null then
    select * into r from public.custom_requests where id = (p->>'request_id')::uuid;
    if r.id is not null then
      foreach f in array coalesce(r.files, '{}') loop
        if f ~* '\.(jpe?g|png|webp|gif|heic|heif)$' then
          insert into public.ws_photos (order_id, path, kind, bucket) values (o_id, f, 'ref', 'request-files');
        end if;
      end loop;
      update public.custom_requests set status = 'in_progress',
        admin_notes = concat_ws(E'\n', nullif(admin_notes, ''), 'Workshop order ' || v_ref) where id = r.id;
    end if;
  end if;

  if p_by = 'manager' then
    perform public.ws_note('alert', 'Manager took a new order ' || v_ref || ': ' || coalesce(p->>'qty', '1') || ' × ' || trim(p->>'item') || ' for ' || trim(p->>'customer'), o_id);
  else
    perform public.ws_note(case when p->>'urgency' = 'urgent' then 'alert' else 'info' end,
      'New order ' || v_ref || ': ' || coalesce(p->>'qty', '1') || ' × ' || trim(p->>'item') || ' for ' || trim(p->>'customer'), o_id);
  end if;
  perform public.ws_advance(o_id);
  perform public.ws_release_all();
  return v_ref;
end $$;

create or replace function public.ws_create_order(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  return public.ws_new_order(p, 'owner');
end $$;

create or replace function public.ws_foreman_create_order(p_pin text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ref text;
begin
  perform public.ws_foreman_ok(p_pin);
  v_ref := public.ws_new_order(p - 'request_id', 'manager');
  return jsonb_build_object('ref', v_ref, 'id', (select id from public.ws_orders where ref = v_ref));
end $$;

-- the manager adds a picture to an order she just took
create or replace function public.ws_foreman_add_photo(p_pin text, p_order uuid, p_path text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  perform public.ws_foreman_ok(p_pin);
  select * into o from public.ws_orders where id = p_order;
  if o.id is null then raise exception 'Order not found'; end if;
  if p_path is null or p_path not like o.id::text || '/%' then raise exception 'Bad photo'; end if;
  insert into public.ws_photos (order_id, path, kind) values (o.id, p_path, 'ref');
  perform public.ws_note('good', 'Manager added a picture of what to make to ' || o.ref, o.id);
end $$;

-- the job card: pictures (and which store they are in)
create or replace function public.ws_job_pics(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w public.ws_workers;
begin
  w := public.ws_me(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('b', p.bucket, 'p', p.path) order by p.id)
                     from public.ws_photos p join public.ws_tasks t on t.order_id = p.order_id
                    where t.id = w.task_id and p.kind = 'ref'), '[]'::jsonb);
end $$;

revoke all on function public.ws_new_order(jsonb, text) from public, anon, authenticated;
revoke all on function public.ws_foreman_create_order(text, jsonb), public.ws_foreman_add_photo(text, uuid, text), public.ws_job_pics(uuid) from public, anon;
grant execute on function public.ws_create_order(jsonb)                       to authenticated;
grant execute on function public.ws_foreman_create_order(text, jsonb)         to authenticated;
grant execute on function public.ws_foreman_add_photo(text, uuid, text)       to authenticated;
grant execute on function public.ws_job_pics(uuid)                            to authenticated;

-- ---------- picture store rules ----------
do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    -- the workshop computer may upload pictures for orders (into the order's own folder)
    drop policy if exists "kartech photos workshop add" on storage.objects;
    create policy "kartech photos workshop add" on storage.objects for insert to authenticated
      with check (bucket_id = 'kartech-photos' and public.ws_is_station()
                  and exists (select 1 from public.ws_orders o where o.id::text = (storage.foldername(name))[1]));
    -- the workshop computer may open customer photos that became "what to make" pictures
    drop policy if exists "request files workshop read" on storage.objects;
    create policy "request files workshop read" on storage.objects for select to authenticated
      using (bucket_id = 'request-files' and public.ws_is_station()
             and exists (select 1 from public.ws_photos p where p.path = storage.objects.name and p.kind = 'ref' and p.bucket = 'request-files'));
  end if;
end $do$;

-- >>>>>>>>>> update-16-order-room.sql
-- =====================================================================
--  KARTECH UPDATE 16: the Order Room (stage 1)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-15-sales.sql first.
--
--  • Every order gets a private link for its customer (and a QR code).
--  • In their Order Room the customer sees their order and its progress,
--    sends photos and messages, and taps "Yes, this is what I want".
--  • Their photos go straight onto the workers' job card; the workers see
--    "Customer approved this design". The owner gets an alert for each.
--  • No login for the customer: the link's random code is the key.
-- =====================================================================

-- a short random code nobody can guess (no 0/o/1/l, easy to read out)
create or replace function public.ws_new_code() returns text
language plpgsql volatile set search_path = public, extensions as $$
declare a text := 'abcdefghjkmnpqrstuvwxyz23456789'; b bytea := extensions.gen_random_bytes(10); r text := ''; i int;
begin
  for i in 0..9 loop r := r || substr(a, (get_byte(b, i) % length(a)) + 1, 1); end loop;
  return r;
end $$;

alter table public.ws_orders add column if not exists room_code text;
alter table public.ws_orders add column if not exists approved_at timestamptz;
update public.ws_orders set room_code = public.ws_new_code() where room_code is null;
alter table public.ws_orders alter column room_code set default public.ws_new_code();
create unique index if not exists ws_orders_room_code on public.ws_orders (room_code);

-- messages between the customer and Kartech, one thread per order
create table if not exists public.ws_room_msgs (
  id       bigserial primary key,
  order_id uuid not null references public.ws_orders(id) on delete cascade,
  at       timestamptz not null default now(),
  who      text not null check (who in ('customer', 'kartech')),
  text     text not null
);
alter table public.ws_room_msgs enable row level security;
drop policy if exists "owner reads room messages" on public.ws_room_msgs;
create policy "owner reads room messages" on public.ws_room_msgs for select to authenticated using (public.is_admin());
grant select on public.ws_room_msgs to authenticated;

-- ---------- what the customer sees ----------
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

create or replace function public.ws_room_add_photo(p_code text, p_path text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then raise exception 'Order not found'; end if;
  if p_path is null or p_path not like 'room/' || o.room_code || '/%' then raise exception 'Bad photo'; end if;
  if (select count(*) from public.ws_photos where order_id = o.id and bucket = 'room-files') >= 40 then raise exception 'That is the most photos for one order. Send a message instead.'; end if;
  insert into public.ws_photos (order_id, path, kind, bucket) values (o.id, p_path, 'ref', 'room-files');
  perform public.ws_note('alert', split_part(trim(o.customer), ' ', 1) || ' sent a new picture for ' || o.ref, o.id);
end $$;

create or replace function public.ws_room_message(p_code text, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; v text := left(trim(coalesce(p_text, '')), 500);
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then raise exception 'Order not found'; end if;
  if length(v) = 0 then raise exception 'Write a message first'; end if;
  if (select count(*) from public.ws_room_msgs where order_id = o.id and who = 'customer' and at > now() - interval '1 hour') >= 30 then raise exception 'Please wait a little before sending more.'; end if;
  insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'customer', v);
  perform public.ws_note('alert', 'Message from ' || split_part(trim(o.customer), ' ', 1) || ' on ' || o.ref || ': ' || left(v, 120), o.id);
end $$;

create or replace function public.ws_room_approve(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders;
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then raise exception 'Order not found'; end if;
  if o.approved_at is not null then return; end if;
  update public.ws_orders set approved_at = now() where id = o.id;
  insert into public.ws_room_msgs (order_id, who, text) values (o.id, 'customer', '✓ Yes, this is what I want');
  perform public.ws_note('good', split_part(trim(o.customer), ' ', 1) || ' approved the design for ' || o.ref, o.id);
end $$;

-- the owner answers in the room
create or replace function public.ws_room_reply(p_order uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare v text := left(trim(coalesce(p_text, '')), 500);
begin
  perform public.ws_need_owner();
  if length(v) = 0 then raise exception 'Write a message first'; end if;
  if not exists (select 1 from public.ws_orders where id = p_order) then raise exception 'Order not found'; end if;
  insert into public.ws_room_msgs (order_id, who, text) values (p_order, 'kartech', v);
end $$;

-- the owner can undo an approval (e.g. the design changed after talking)
create or replace function public.ws_room_unapprove(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  update public.ws_orders set approved_at = null where id = p_order;
end $$;

-- the manager sees the customer link of an order she just took
create or replace function public.ws_foreman_room_code(p_pin text, p_order uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_foreman_ok(p_pin);
  return (select room_code from public.ws_orders where id = p_order);
end $$;

-- the worker's job card also says whether the customer approved
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
   where q.stage = w.stage and q.status = 'queued' order by q.rank limit 1;
  return jsonb_build_object(
    'worker', jsonb_build_object('name', w.name, 'stage', w.stage),
    'task', case when t.id is null then null else jsonb_build_object(
      'status', t.status, 'stage', t.stage, 'problem_reason', t.problem_reason, 'problem_stopped', t.problem_stopped,
      'problem_ack', t.problem_ack_at is not null, 'with', mates, 'approved', o.approved_at) end,
    'order', case when o.id is null then null else jsonb_build_object(
      'ref', o.ref, 'item', o.item, 'qty', o.qty, 'deadline', o.deadline, 'urgency', o.urgency, 'notes', o.notes) end,
    'after', after_stage,
    'next', case when nxt.ref is null then null else jsonb_build_object('ref', nxt.ref, 'qty', nxt.qty, 'item', nxt.item) end);
end $$;

revoke all on function public.ws_new_code() from public, anon, authenticated;
revoke all on function public.ws_room(text), public.ws_room_add_photo(text, text), public.ws_room_message(text, text), public.ws_room_approve(text) from public;
grant execute on function public.ws_room(text)                    to anon, authenticated;
grant execute on function public.ws_room_add_photo(text, text)    to anon, authenticated;
grant execute on function public.ws_room_message(text, text)      to anon, authenticated;
grant execute on function public.ws_room_approve(text)            to anon, authenticated;
revoke all on function public.ws_room_reply(uuid, text), public.ws_room_unapprove(uuid), public.ws_foreman_room_code(text, uuid) from public, anon;
grant execute on function public.ws_room_reply(uuid, text)        to authenticated;
grant execute on function public.ws_room_unapprove(uuid)          to authenticated;
grant execute on function public.ws_foreman_room_code(text, uuid) to authenticated;
grant execute on function public.ws_my_job(uuid)                  to authenticated;

-- ---------- the customers' photo store (secret addresses, no listing) ----------
do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('room-files', 'room-files', true, 10485760, array['image/jpeg','image/png','image/webp','image/gif','image/heic','image/heif'])
    on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

    drop policy if exists "room files customer add"  on storage.objects;
    drop policy if exists "room files customer read" on storage.objects;
    drop policy if exists "room files owner read"    on storage.objects;
    drop policy if exists "room files workshop read" on storage.objects;
    -- a customer may add photos only inside their own room's folder (room/<their code>/<random name>).
    -- Nobody may LIST the folders; a photo opens only with its full secret address
    -- (the room code + a random file name), which only that room knows.
    create policy "room files customer add" on storage.objects for insert to anon, authenticated
      with check (bucket_id = 'room-files' and (storage.foldername(name))[1] = 'room'
                  and exists (select 1 from public.ws_orders o where o.room_code = (storage.foldername(name))[2]));
    create policy "room files owner read" on storage.objects for select to authenticated
      using (bucket_id = 'room-files' and public.is_admin());
  end if;
end $do$;

-- >>>>>>>>>> update-17-client-links.sql
-- =====================================================================
--  UPDATE 17: the manager can send any client their Order Room link
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Needs update-16 first.
-- =====================================================================

-- open orders with their client link code, newest first (no money, ever)
create or replace function public.ws_foreman_rooms(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_foreman_ok(p_pin);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'ref', o.ref, 'customer', o.customer, 'item', o.item, 'qty', o.qty,
             'notes', o.notes, 'room', o.room_code, 'approved', o.approved_at, 'at', o.created_at)
           order by o.created_at desc)
    from (select * from public.ws_orders
          where delivered_at is null and room_code is not null
          order by created_at desc limit 80) o
  ), '[]'::jsonb);
end $$;

revoke all on function public.ws_foreman_rooms(text) from public, anon;
grant execute on function public.ws_foreman_rooms(text) to authenticated;

-- >>>>>>>>>> update-18-payments.sql
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
