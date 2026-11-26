-- =====================================================================
--  UPDATE 32: the client sees what she ordered
--  • Her Order Room gets a "What you ordered" card at the top: every
--    item, how many, the fabric (with its photo) and the design pictures.
--  • In "find my orders by phone", each order shows a small picture.
--  • Design pictures ("what to make") now go to the client-visible photo
--    store (room-files, folder "design/"). Old ones move over by
--    themselves the next time the owner opens the order.
--  • Finished-work photos stay private, as before.
--  • Prices, workers and notes are NEVER shown to the client.
--  Needs updates 16, 19, 29, 30, 31 first.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================

-- the owner and the workshop computer may put design pictures in design/<order id>/…
do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    drop policy if exists "room files staff add design" on storage.objects;
    create policy "room files staff add design" on storage.objects for insert to authenticated
      with check (bucket_id = 'room-files' and (storage.foldername(name))[1] = 'design'
                  and (public.is_admin() or public.ws_is_station()));
  end if;
end $do$;

-- OWNER: add a photo (design pictures may now sit in room-files/design/<order>/…)
create or replace function public.ws_add_photo(p_order uuid, p_path text, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; k text := case when p_kind = 'ref' then 'ref' else 'done' end; b text := 'kartech-photos';
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order;
  if o.id is null then raise exception 'Order not found'; end if;
  if k = 'ref' and p_path like 'design/' || o.id::text || '/%' then b := 'room-files';
  elsif p_path is null or p_path not like o.id::text || '/%' then raise exception 'Bad photo'; end if;
  insert into public.ws_photos (order_id, path, kind, bucket) values (o.id, p_path, k, b);
  perform public.ws_note('good', case when k = 'ref' then 'Picture of what to make added to ' else 'Photo of finished work added to ' end || o.ref, o.id);
end $$;

-- MANAGER: add a design picture to an order she just took
create or replace function public.ws_foreman_add_photo(p_pin text, p_order uuid, p_path text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; b text := 'kartech-photos';
begin
  perform public.ws_foreman_ok(p_pin);
  select * into o from public.ws_orders where id = p_order;
  if o.id is null then raise exception 'Order not found'; end if;
  if p_path like 'design/' || o.id::text || '/%' then b := 'room-files';
  elsif p_path is null or p_path not like o.id::text || '/%' then raise exception 'Bad photo'; end if;
  insert into public.ws_photos (order_id, path, kind, bucket) values (o.id, p_path, 'ref', b);
  perform public.ws_note('good', 'Manager added a picture of what to make to ' || o.ref, o.id);
end $$;

-- OWNER: an old design picture was copied to room-files; point the photo at the copy
create or replace function public.kt_photo_to_room(p_photo bigint, p_path text) returns void
language plpgsql security definer set search_path = public as $$
declare ph public.ws_photos;
begin
  perform public.ws_need_owner();
  select * into ph from public.ws_photos where id = p_photo;
  if ph.id is null or ph.kind <> 'ref' or ph.bucket <> 'kartech-photos' then raise exception 'Photo not found'; end if;
  if p_path not like 'design/' || ph.order_id::text || '/%' then raise exception 'Bad photo'; end if;
  update public.ws_photos set bucket = 'room-files', path = p_path where id = ph.id;
end $$;

-- CLIENT (with the room code): what she ordered. No prices, no workers, no notes.
create or replace function public.ws_room_order(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o public.ws_orders;
begin
  select * into o from public.ws_orders where room_code = lower(trim(p_code));
  if o.id is null then return null; end if;
  return jsonb_build_object(
    'lines', case when o.lines is not null then
               (select jsonb_agg(jsonb_build_object('item', x->>'item', 'qty', (x->>'qty')::int, 'fabric', x->>'fabric', 'hex', x->>'hex', 'photo', f.photo) order by i)
                  from jsonb_array_elements(o.lines) with ordinality t(x, i)
                  left join public.kt_fabrics f on f.id = nullif(x->>'fabric_id', '')::uuid)
             else jsonb_build_array(jsonb_build_object('item', o.item, 'qty', o.qty, 'fabric', o.fabric, 'hex', o.fabric_hex,
                    'photo', (select f.photo from public.kt_fabrics f where f.id = o.fabric_id))) end,
    'design', (select coalesce(jsonb_agg(p.path order by p.id), '[]'::jsonb) from public.ws_photos p
                where p.order_id = o.id and p.kind = 'ref' and p.bucket = 'room-files' and p.path like 'design/%'));
end $$;

-- CLIENT: find my orders by phone, now with a small picture for each
create or replace function public.ws_find_rooms(p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if length(d) < 9 then raise exception 'Type your full phone number, e.g. 0712 345 678'; end if;
  d := right(d, 9);
  return coalesce((
    select jsonb_agg(jsonb_build_object('ref', o.ref, 'item', o.item, 'qty', o.qty, 'code', o.room_code,
                                        'delivered', o.delivered_at is not null,
                                        'thumb', (select p.path from public.ws_photos p where p.order_id = o.id and p.kind = 'ref'
                                                    and p.bucket = 'room-files' and p.path like 'design/%' order by p.id limit 1),
                                        'hex', coalesce(o.fabric_hex, o.lines->0->>'hex')) order by o.created_at desc)
    from public.ws_orders o
    where o.room_code is not null
      and (o.delivered_at is null or o.delivered_at > now() - interval '60 days')
      and (regexp_replace(o.customer, '\D', '', 'g') like '%' || d || '%'
           or regexp_replace(coalesce(o.notes, ''), '\D', '', 'g') like '%' || d || '%'
           or exists (select 1 from public.orders w where w.id = o.source_order_id
                        and regexp_replace(coalesce(w.phone, ''), '\D', '', 'g') like '%' || d))
  ), '[]'::jsonb);
end $$;

revoke all on function public.kt_photo_to_room(bigint, text) from public, anon;
grant execute on function public.kt_photo_to_room(bigint, text) to authenticated;
grant execute on function public.ws_room_order(text) to anon, authenticated;
grant execute on function public.ws_find_rooms(text) to anon, authenticated;
