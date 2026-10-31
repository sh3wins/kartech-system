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
