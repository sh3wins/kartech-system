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

create or replace function public.ws_room_ok(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.ws_orders where room_code = lower(trim(p_code)));
$$;
grant execute on function public.ws_room_ok(text) to anon, authenticated;

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
                  and public.ws_room_ok((storage.foldername(name))[2]));
    create policy "room files owner read" on storage.objects for select to authenticated
      using (bucket_id = 'room-files' and public.is_admin());
  end if;
end $do$;
