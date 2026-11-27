-- =====================================================================
--  UPDATE 35: reply to the customer with a picture
--  • In the Order Room, the owner can send a photo (with a few words or
--    none): a sketch, a sample, the chair being made.
--  • The customer sees it in her chat and can tap it to see it big.
--  • Pictures go in the public room-files store, folder "reply/",
--    at secret addresses (like the customer's own pictures).
--  Needs update 16 (Order Room) and 34 first.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
alter table public.ws_room_msgs add column if not exists photo text;

do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    drop policy if exists "room files owner adds replies" on storage.objects;
    create policy "room files owner adds replies" on storage.objects for insert to authenticated
      with check (bucket_id = 'room-files' and (storage.foldername(name))[1] = 'reply' and public.is_admin());
  end if;
end $do$;

-- OWNER: send a picture to the customer (words optional)
create or replace function public.ws_room_reply_photo(p_order uuid, p_path text, p_text text default '') returns void
language plpgsql security definer set search_path = public as $$
declare v text := left(trim(coalesce(p_text, '')), 500);
begin
  perform public.ws_need_owner();
  if not exists (select 1 from public.ws_orders where id = p_order) then raise exception 'Order not found'; end if;
  if p_path is null or p_path not like 'reply/' || p_order::text || '/%' or p_path ~ '\.\.' then raise exception 'Bad picture'; end if;
  insert into public.ws_room_msgs (order_id, who, text, photo) values (p_order, 'kartech', v, p_path);
end $$;

-- CUSTOMER: her Order Room, now with pictures in the chat
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
    'msgs', (select coalesce(jsonb_agg(jsonb_build_object('who', m.who, 'text', m.text, 'at', m.at, 'photo', m.photo) order by m.id), '[]'::jsonb)
               from (select * from public.ws_room_msgs where order_id = o.id order by id desc limit 100) m));
end $$;


revoke all on function public.ws_room_reply_photo(uuid, text, text) from public, anon;
grant execute on function public.ws_room_reply_photo(uuid, text, text) to authenticated;
grant execute on function public.ws_room(text) to anon, authenticated;
