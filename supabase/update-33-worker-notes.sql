-- =====================================================================
--  UPDATE 33: notes on each worker
--  • The owner can write dated notes on a worker, e.g. "took 5 m red
--    leatherette", "borrowed the big grinder", "off on Friday".
--  • "Fabric taken": pick the fabric and the metres. It writes the note
--    AND takes those metres off the fabric stock in one go. Deleting
--    that note puts the metres back.
--  • Only the owner sees these notes. Workers and the manager don't.
--  • Notes stay if a worker goes to the Bin, and come back with them.
--  Needs update 29 (fabrics) first.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
create table if not exists public.ws_worker_notes (
  id         bigint generated always as identity primary key,
  worker_id  uuid not null,
  body       text not null check (length(body) between 1 and 500),
  fabric_id  uuid references public.kt_fabrics(id) on delete set null,
  metres     numeric check (metres is null or metres > 0),
  created_at timestamptz not null default now()
);
create index if not exists ws_worker_notes_worker on public.ws_worker_notes (worker_id, created_at desc);

alter table public.ws_worker_notes enable row level security;
drop policy if exists "owner reads worker notes" on public.ws_worker_notes;
create policy "owner reads worker notes" on public.ws_worker_notes for select to authenticated using (public.is_admin());
revoke all on public.ws_worker_notes from anon, authenticated;
grant select on public.ws_worker_notes to authenticated;

-- OWNER: add a note; with a fabric and metres, the metres come off the fabric stock
create or replace function public.ws_add_worker_note(p_worker uuid, p_body text, p_fabric uuid default null, p_metres numeric default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare b text := left(trim(coalesce(p_body, '')), 500); f public.kt_fabrics; nid bigint;
begin
  perform public.ws_need_owner();
  if not exists (select 1 from public.ws_workers where id = p_worker) then raise exception 'Worker not found'; end if;
  if p_fabric is not null then
    select * into f from public.kt_fabrics where id = p_fabric;
    if f.id is null then raise exception 'Fabric not found'; end if;
    if coalesce(p_metres, 0) <= 0 then raise exception 'How many metres?'; end if;
    if p_metres > 10000 then raise exception 'That is too many metres'; end if;
    b := 'Took ' || trim(trailing '.' from trim(trailing '0' from round(p_metres, 2)::text)) || ' m ' || f.kind || ' · ' || f.colour || case when b <> '' then ': ' || b else '' end;
    update public.kt_fabrics set metres = greatest(metres - p_metres, 0), updated_at = now() where id = f.id;
  else
    if b = '' then raise exception 'Write something first'; end if;
    p_metres := null;
  end if;
  insert into public.ws_worker_notes (worker_id, body, fabric_id, metres) values (p_worker, left(b, 500), f.id, p_metres) returning id into nid;
  return nid;
end $$;

-- OWNER: delete a note; a "fabric taken" note puts its metres back
create or replace function public.ws_delete_worker_note(p_note bigint) returns void
language plpgsql security definer set search_path = public as $$
declare n public.ws_worker_notes;
begin
  perform public.ws_need_owner();
  delete from public.ws_worker_notes where id = p_note returning * into n;
  if n.id is null then raise exception 'Note not found'; end if;
  if n.fabric_id is not null and n.metres is not null then
    update public.kt_fabrics set metres = metres + n.metres, updated_at = now() where id = n.fabric_id;
  end if;
end $$;

revoke all on function public.ws_add_worker_note(uuid, text, uuid, numeric), public.ws_delete_worker_note(bigint) from public, anon;
grant execute on function public.ws_add_worker_note(uuid, text, uuid, numeric), public.ws_delete_worker_note(bigint) to authenticated;
