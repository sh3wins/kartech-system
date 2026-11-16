# Setup guide

How to set up the Kartech Workshop System from nothing. Kartech's live system is already set up, so you only need this guide for a **new Supabase project**, a **test copy**, or a **new client** on the same system.

Steps 1–3 happen once. It takes about 20 minutes.

---

## 1. The database (Supabase)

1. Make a Supabase project at https://supabase.com, or use the one the website already uses (Kartech shares one project between the website and the workshop).
2. Open **SQL Editor → New query**.
3. Open `supabase/INSTALL-ALL.sql`, copy **all** of it, paste it in and press **Run**.
   It should end with *Success. No rows returned*.
4. New query again: paste all of `supabase/which-updates.sql` and press **Run**. Every row should say **yes**.

`INSTALL-ALL.sql` creates every table, function, rule and storage folder, in the right order. It is safe to run on a project that already has the website set up: the website part (`00-website-basics`) checks first and changes nothing that already exists.

> **Updating an existing project?** Don't run INSTALL-ALL blindly. Read [`DATABASE.md`](DATABASE.md) first.

## 2. Turn off public sign-ups (important)

Every account in this system is made by hand (the owner and the workshop computer), so nobody should be able to sign themselves up.

Supabase → **Authentication → Sign In / Providers** → turn **off** *Allow new users to sign up*.

(Check with the website first: the Kartech website takes orders without customers logging in, so turning this off does not affect it.)

## 3. Accounts

### The owner
1. Supabase → **Authentication → Users → Add user → Create new user**: the owner's email, a strong password, tick **Auto confirm user**.
2. SQL Editor → New query → Run (put in her email):
   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = 'OWNER-EMAIL'
   on conflict do nothing;
   ```

### The workshop computer
1. **Add user** again with an email like `workshop@kartech.co.ke` (it does not need to be a real inbox), a strong password and **Auto confirm user**.
2. Run:
   ```sql
   insert into public.ws_stations (user_id)
   select id from auth.users where email = 'workshop@kartech.co.ke'
   on conflict do nothing;
   ```

> Never put the workshop account in `admins`. It would then see all the money. The security check tests this.

## 4. Connect the pages to the database

Open `js/config.js` and set:

| Setting | Where to find it |
|---|---|
| `supabaseUrl` | Supabase → Project Settings → API → Project URL |
| `supabaseKey` | Supabase → Project Settings → API Keys → the **publishable** key (`sb_publishable_…`) |
| `stationIdleSeconds` | How long the workshop computer waits before signing a worker out (default 60) |
| `toolCheckAt` | Closing time for the manager's evening tool check (default `18:30`) |

The publishable key is meant to be public; the database rules protect the data. **Never** put the `service_role` / secret key in any file here.

## 5. Put it online (GitHub Pages)

1. Push the folder to a GitHub repository.
2. GitHub → the repo → **Settings → Pages** → Source: *Deploy from a branch* → `main` / root → Save.
3. After a minute the site is at `https://YOUR-NAME.github.io/REPO-NAME/`.

Every `git push` to `main` updates the live site. Hard-refresh with **Ctrl + Shift + R** to see changes.

## 6. Check it

Run these in Supabase SQL Editor, one after the other (details in [`TESTING.md`](TESTING.md)):

1. `supabase/check-security.sql`: every row **PASS**
2. `tests/business-rules.sql`: every row **PASS**

## 7. First day (the owner)

1. Open the site and choose **Owner**, then sign in.
2. **Voice & settings** (bottom of the left menu, or the gear on a phone):
   - **Business details** (phone, KRA PIN, address): printed on invoices and receipts.
   - **Payments**: the M-Pesa number and name clients pay to.
3. **Workers** page:
   - Add each worker with their trade and a 4-digit PIN.
   - **Manager code**: set the code the manager uses on the workshop screen.
   - **Workshop steps** → *Edit steps*: rename, add or hide steps if Kartech's differ.
4. **Stock:** check the tools and materials list.
5. On the workshop computer, open the site, choose **Workshop** and sign in once with the workshop login. Leave it open all day.
6. Add the first order. When the deposit is recorded, the jobs flow to workers by themselves.

## Good to know

- Worker PINs and the manager code are stored scrambled. Nobody can read them, not even the owner. If a PIN is forgotten, set a new one.
- 5 wrong PINs locks that worker (or the manager code) for 5 minutes.
- New orders wait **on hold** until the first payment is recorded. Any confirmed payment starts the work.
- An order can only be marked delivered once it is **fully paid**.
- Deleted orders, workers and pictures go to the **Bin** (the 🗑 Bin button at the bottom of the Orders and Workers pages). They can be brought back for 30 days.
