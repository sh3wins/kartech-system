-- =====================================================================
--  UPDATE 20: a client finds their order with their phone number
--  (no link to keep). Paste ALL into Supabase → SQL Editor → Run.
--  Safe to run again.
-- =====================================================================
create or replace function public.ws_find_rooms(p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  -- the last 9 digits of a Kenyan number: 0712 345 678 / +254 712 345 678 → 712345678
  if length(d) < 9 then raise exception 'Type your full phone number, e.g. 0712 345 678'; end if;
  d := right(d, 9);
  return coalesce((
    select jsonb_agg(jsonb_build_object('ref', o.ref, 'item', o.item, 'qty', o.qty, 'code', o.room_code,
                                        'delivered', o.delivered_at is not null) order by o.created_at desc)
    from public.ws_orders o
    where o.room_code is not null
      and (o.delivered_at is null or o.delivered_at > now() - interval '60 days')
      and (regexp_replace(o.customer, '\D', '', 'g') like '%' || d || '%'
           or regexp_replace(coalesce(o.notes, ''), '\D', '', 'g') like '%' || d || '%'
           or exists (select 1 from public.orders w where w.id = o.source_order_id
                        and regexp_replace(coalesce(w.phone, ''), '\D', '', 'g') like '%' || d))
  ), '[]'::jsonb);
end $$;
grant execute on function public.ws_find_rooms(text) to anon, authenticated;
