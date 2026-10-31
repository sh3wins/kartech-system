-- =====================================================================
--  KARTECH UPDATE 14: pictures of what to make (workers see them)
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again. Run update-12-all.sql first.
--
--  • Each order can have pictures of WHAT TO MAKE: the customer's sample,
--    a sketch, a fabric colour. Workers see them on their job card, so
--    nothing depends on word of mouth.
--  • "Finished work" photos stay private to the owner, like before.
-- =====================================================================

alter table public.ws_photos add column if not exists kind text not null default 'done';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'ws_photos_kind_check') then
    alter table public.ws_photos add constraint ws_photos_kind_check check (kind in ('ref', 'done'));
  end if;
end $$;

-- the owner sees all photos; the workshop computer sees only "what to make" pictures
drop policy if exists "owner reads photos" on public.ws_photos;
create policy "owner reads photos" on public.ws_photos for select to authenticated
  using (public.is_admin() or (kind = 'ref' and public.ws_is_station()));

create or replace function public.ws_add_photo(p_order uuid, p_path text, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare o public.ws_orders; k text := case when p_kind = 'ref' then 'ref' else 'done' end;
begin
  perform public.ws_need_owner();
  select * into o from public.ws_orders where id = p_order;
  if o.id is null then raise exception 'Order not found'; end if;
  if p_path is null or p_path not like o.id::text || '/%' then raise exception 'Bad photo'; end if;
  insert into public.ws_photos (order_id, path, kind) values (o.id, p_path, k);
  perform public.ws_note('good', case when k = 'ref' then 'Picture of what to make added to ' else 'Photo of finished work added to ' end || o.ref, o.id);
end $$;

-- the worker's job card: pictures for the order they are working on
create or replace function public.ws_job_pictures(p_token uuid) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare w public.ws_workers;
begin
  w := public.ws_me(p_token);
  return coalesce((select array_agg(p.path order by p.id) from public.ws_photos p join public.ws_tasks t on t.order_id = p.order_id
                    where t.id = w.task_id and p.kind = 'ref'), '{}');
end $$;

revoke all on function public.ws_add_photo(uuid, text, text), public.ws_job_pictures(uuid) from public, anon;
grant execute on function public.ws_add_photo(uuid, text, text) to authenticated;
grant execute on function public.ws_job_pictures(uuid)          to authenticated;

-- the workshop computer may open "what to make" pictures (never finished-work photos)
do $do$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    drop policy if exists "kartech photos workshop read" on storage.objects;
    create policy "kartech photos workshop read" on storage.objects for select to authenticated
      using (bucket_id = 'kartech-photos' and public.ws_is_station()
             and exists (select 1 from public.ws_photos p where p.path = storage.objects.name and p.kind = 'ref'));
  end if;
end $do$;
