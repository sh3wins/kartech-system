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
