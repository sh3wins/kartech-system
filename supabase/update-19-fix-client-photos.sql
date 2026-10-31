-- =====================================================================
--  UPDATE 19: fix "permission denied for table ws_orders" when a client
--  adds a photo in their Order Room.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================

-- checks a room code without giving clients access to the orders table
create or replace function public.ws_room_ok(p_code text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.ws_orders where room_code = lower(trim(p_code)));
$$;
grant execute on function public.ws_room_ok(text) to anon, authenticated;

drop policy if exists "room files customer add" on storage.objects;
create policy "room files customer add" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'room-files' and (storage.foldername(name))[1] = 'room'
              and public.ws_room_ok((storage.foldername(name))[2]));
