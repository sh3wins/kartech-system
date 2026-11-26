-- =====================================================================
--  UPDATE 28: messages between the owner and each worker
--  • The owner writes to one worker from her app (Messages).
--  • The worker reads and replies on the workshop screen, after tapping
--    their name and PIN. A worker only ever sees their own messages.
--  • The manager does not see these messages.
--  Paste ALL of this into Supabase → SQL Editor → New query → Run.
--  Safe to run again.
-- =====================================================================
create table if not exists public.ws_messages (
  id         bigserial primary key,
  worker_id  uuid not null references public.ws_workers(id) on delete cascade,
  from_owner boolean not null,
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists ws_messages_worker on public.ws_messages (worker_id, created_at desc);
alter table public.ws_messages enable row level security;
drop policy if exists "owner reads messages" on public.ws_messages;
create policy "owner reads messages" on public.ws_messages for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.ws_messages from anon, authenticated;

-- OWNER: send a message to one worker
create or replace function public.ws_owner_msg(p_worker uuid, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v text := left(trim(coalesce(p_body, '')), 1000); nid bigint;
begin
  perform public.ws_need_owner();
  if v = '' then raise exception 'Write a message first'; end if;
  if not exists (select 1 from public.ws_workers where id = p_worker) then raise exception 'Worker not found'; end if;
  insert into public.ws_messages (worker_id, from_owner, body) values (p_worker, true, v) returning id into nid;
  return nid;
end $$;

-- OWNER: she has read a worker's messages
create or replace function public.ws_owner_msg_read(p_worker uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ws_need_owner();
  update public.ws_messages set read_at = now() where worker_id = p_worker and not from_owner and read_at is null;
end $$;

-- WORKER (signed in on the workshop screen): my messages, newest last. Opening them marks the owner's ones as read.
create or replace function public.ws_my_msgs(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; out jsonb;
begin
  w := public.ws_me(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'me', not from_owner, 'body', body, 'at', created_at, 'read', read_at is not null) order by created_at), '[]')
    into out from (select * from public.ws_messages where worker_id = w.id order by created_at desc limit 60) m;
  update public.ws_messages set read_at = now() where worker_id = w.id and from_owner and read_at is null;
  return out;
end $$;

-- WORKER: reply to the owner
create or replace function public.ws_my_msg_send(p_token uuid, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare w public.ws_workers; v text := left(trim(coalesce(p_body, '')), 1000); nid bigint;
begin
  w := public.ws_me(p_token);
  if v = '' then raise exception 'Write a message first'; end if;
  insert into public.ws_messages (worker_id, from_owner, body) values (w.id, false, v) returning id into nid;
  return nid;
end $$;

-- WORKSHOP SCREEN: which workers have a new message from the owner (counts only, no text)
create or replace function public.ws_station_unread() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (public.ws_is_station() or public.is_admin()) then raise exception 'This computer is not set up as the workshop PC'; end if;
  return coalesce((select jsonb_object_agg(worker_id, n) from (select worker_id, count(*) n from public.ws_messages
                    where from_owner and read_at is null group by worker_id) x), '{}'::jsonb);
end $$;

revoke all on function public.ws_owner_msg(uuid, text), public.ws_owner_msg_read(uuid), public.ws_my_msgs(uuid),
  public.ws_my_msg_send(uuid, text), public.ws_station_unread() from public, anon;
grant execute on function public.ws_owner_msg(uuid, text), public.ws_owner_msg_read(uuid), public.ws_my_msgs(uuid),
  public.ws_my_msg_send(uuid, text), public.ws_station_unread() to authenticated;
