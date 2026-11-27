-- =====================================================================
--  UPDATE 34: the owner can delete Order Room messages
--  • A small 🗑 on each message in the Order Room (owner app only).
--    Tap it twice to delete. It disappears for the customer too.
--  • Customers, the manager and workers cannot delete messages.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
create or replace function public.ws_room_msg_delete(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  delete from public.ws_room_msgs where id = p_id;
  if not found then raise exception 'Message not found'; end if;
end $$;

revoke all on function public.ws_room_msg_delete(bigint) from public, anon;
grant execute on function public.ws_room_msg_delete(bigint) to authenticated;
