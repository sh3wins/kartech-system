-- =====================================================================
--  UPDATE 30: a photo on each fabric
--  • Each fabric can have a real photo of the material (as well as its
--    colour swatch). The owner adds it in Stock → Fabrics.
--  • The photo shows on the fabric list, on orders, on the workshop
--    screen and on the worker's job card.
--  • Photos go in the public "shop-photos" folder (from update 26).
--  Needs update 26 and update 29 first.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
alter table public.kt_fabrics add column if not exists photo text;

-- OWNER: add or change a fabric (now with an optional photo)
create or replace function public.kt_save_fabric(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; k text := left(trim(coalesce(p->>'kind', '')), 60); c text := left(trim(coalesce(p->>'colour', '')), 60);
        h text := coalesce(nullif(trim(p->>'hex'), ''), '#888888');
        ph text := nullif(trim(coalesce(p->>'photo', '')), '');
begin
  perform public.ws_need_owner();
  if k = '' or c = '' then raise exception 'Give the fabric a type and a colour'; end if;
  if h !~ '^#[0-9A-Fa-f]{6}$' then h := '#888888'; end if;
  if ph is not null and ph !~ '^https?://[^\s"''<>]+$' then raise exception 'That photo link does not look right'; end if;
  if exists (select 1 from public.kt_fabrics where active and lower(kind) = lower(k) and lower(colour) = lower(c) and id is distinct from v_id) then
    raise exception '% · % is already on the list', k, c; end if;
  if v_id is null then
    insert into public.kt_fabrics (kind, colour, hex, metres, low_at, photo) values (k, c, h, greatest(coalesce((p->>'metres')::numeric, 0), 0), greatest(coalesce((p->>'low_at')::numeric, 5), 0), ph) returning id into v_id;
  else
    update public.kt_fabrics set kind = k, colour = c, hex = h,
      metres = case when p ? 'metres' then greatest((p->>'metres')::numeric, 0) else metres end,
      low_at = case when p ? 'low_at' then greatest((p->>'low_at')::numeric, 0) else low_at end,
      photo  = case when p ? 'photo' then ph else photo end,
      active = coalesce((p->>'active')::boolean, active), updated_at = now()
    where id = v_id;
  end if;
  return v_id;
end $$;

-- WORKER: the fabric on my current job, now with its photo
create or replace function public.ws_job_fabric(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; r jsonb;
begin
  w := public.ws_me(p_token);
  select jsonb_build_object('name', o.fabric, 'hex', o.fabric_hex, 'photo', f.photo) into r
    from public.ws_tasks t join public.ws_orders o on o.id = t.order_id
    left join public.kt_fabrics f on f.id = o.fabric_id
   where t.id = w.task_id and o.fabric is not null;
  return r;
end $$;

revoke all on function public.kt_save_fabric(jsonb), public.ws_job_fabric(uuid) from public, anon;
grant execute on function public.kt_save_fabric(jsonb), public.ws_job_fabric(uuid) to authenticated;
