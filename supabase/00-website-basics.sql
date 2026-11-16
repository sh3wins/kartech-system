-- =====================================================================
--  STEP 0 (only for a brand-new Supabase project)
--  The workshop system shares one Supabase project with the Kartech
--  website. It needs four things the website normally creates:
--    • public.admins         (who is the owner)
--    • public.is_admin()     (is the signed-in person the owner?)
--    • public.orders         (orders placed on the website)
--    • public.custom_requests (quote requests from the website)
--  If the website is already set up in this project, this file changes
--  NOTHING (every part checks first). Safe to run again.
-- =====================================================================

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'admins' and policyname = 'see own admin row') then
    create policy "see own admin row" on public.admins for select using (user_id = auth.uid());
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'is_admin') then
    execute $f$
      create function public.is_admin() returns boolean
      language sql stable security definer set search_path = public as
      $b$ select exists (select 1 from public.admins where user_id = auth.uid()) $b$ $f$;
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'touch_updated_at') then
    execute $f$
      create function public.touch_updated_at() returns trigger language plpgsql as
      $b$ begin new.updated_at := now(); return new; end $b$ $f$;
  end if;
end $$;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_no text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  status text not null default 'received'
    check (status in ('received','confirmed','workshop','ready','delivered','cancelled')),
  status_note text,
  customer_name text not null,
  phone text not null,
  phone_digits text not null,
  email text,
  fulfilment text not null,
  delivery_location text,
  notes text,
  items jsonb not null,
  subtotal numeric not null default 0,
  unpriced_items integer not null default 0
);
alter table public.orders enable row level security;

create table if not exists public.custom_requests (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  status text not null default 'new'
    check (status in ('new','contacted','quoted','in_progress','closed')),
  admin_notes text,
  need text not null,
  space text,
  name text not null,
  phone text,
  email text,
  files text[] not null default '{}'
);
alter table public.custom_requests enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'orders' and policyname = 'admins read orders') then
    create policy "admins read orders" on public.orders for select using (public.is_admin());
    create policy "admins update orders" on public.orders for update using (public.is_admin()) with check (public.is_admin());
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'custom_requests' and policyname = 'admins read requests') then
    create policy "admins read requests" on public.custom_requests for select using (public.is_admin());
    create policy "admins update requests" on public.custom_requests for update using (public.is_admin()) with check (public.is_admin());
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'orders_touch') then
    create trigger orders_touch before update on public.orders for each row execute function public.touch_updated_at();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'requests_touch') then
    create trigger requests_touch before update on public.custom_requests for each row execute function public.touch_updated_at();
  end if;
end $$;
