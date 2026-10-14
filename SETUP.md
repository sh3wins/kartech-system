# Kartech Workshop system: setup

Two pages, one database (the same `kartech` Supabase project as the website):

| Page | Who | What |
|---|---|---|
| `index.html` | Owner (phone or computer) | Today, Orders, Workshop lines, Workers, alarm |
| `station.html` | The shared workshop computer | Workers tap their name + PIN and see only their own job |
| `demo.html` | Anyone | The clickable demo with sample data (nothing is saved) |

## 1. Create the tables (once)
Supabase → SQL Editor → New query → paste all of `supabase/setup-workshop.sql` → Run.

## 2. Make the workshop computer login (once)
Supabase → Authentication → Users → Add user → Create new user
- Email: `workshop@kartech.co.ke` (it doesn't need to be a real inbox)
- A strong password. Tick **Auto confirm user**.

Then SQL Editor → New query → Run:
```sql
insert into public.ws_stations (user_id)
select id from auth.users where email = 'workshop@kartech.co.ke'
on conflict do nothing;
```

## 3. Owner login
The owner uses the same login as the website's admin page (anyone in `public.admins`).
To add Kartech's own owner later: create the user, then
```sql
insert into public.admins (user_id) select id from auth.users where email = 'OWNER-EMAIL' on conflict do nothing;
```

## 4. Day one
1. Owner opens the site, goes to **Workers**, adds each worker with a 4-digit PIN.
2. On the workshop computer, open `station.html` and sign in once with the workshop login. Leave it open.
3. Owner adds orders. Jobs flow to workers by themselves.

## Good to know
- PINs are stored scrambled. Nobody can read them, not even the owner. Forgotten PIN = set a new one.
- 5 wrong PINs locks that worker for 5 minutes.
- The workshop computer signs a worker out after 60 seconds with no taps (change in `js/config.js`).
- The alarm (siren + vibration) works while the owner has the app open. SMS and phone call steps need an SMS service (e.g. Africa's Talking), not connected yet.
- Free Supabase projects pause after about a week with no use. Daily use keeps it awake.
