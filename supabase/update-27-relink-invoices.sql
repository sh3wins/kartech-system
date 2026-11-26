-- =====================================================================
--  UPDATE 27: an order brought back from the Bin gets its invoice back
--  When an order was deleted, its invoice stayed in Finance (on purpose)
--  but lost its link to the order. Bringing the order back from the Bin
--  did not reconnect them, so the order showed "No invoice yet".
--  • Reconnects every invoice that lost its order, by order number.
--  • From now on, an order coming back reconnects its invoice by itself.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
update public.kt_invoices i set order_id = o.id
  from public.ws_orders o
 where i.order_id is null and i.order_ref is not null and i.order_ref = o.ref;

create or replace function public.kt_relink_invoices() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.kt_invoices set order_id = new.id where order_id is null and order_ref = new.ref;
  return null;
end $$;
revoke all on function public.kt_relink_invoices() from public, anon, authenticated;

drop trigger if exists kt_relink_invoices on public.ws_orders;
create trigger kt_relink_invoices after insert on public.ws_orders
  for each row execute function public.kt_relink_invoices();
