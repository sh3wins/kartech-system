# Security guide

## The people, and what each one may do

| Who | How they get in | What they can do |
|---|---|---|
| **Owner** | Her own email login, listed in `public.admins` | Everything, including all money |
| **Workshop computer** | One shared login, listed in `public.ws_stations` | Shows the workshop screen. Nothing happens until a worker or the manager identifies themselves |
| **Worker** | Taps their name and types their 4-digit PIN on the workshop computer | Sees and finishes **only their own job** |
| **Manager** | Types the manager code on the workshop computer | Attendance, tools, materials, giving jobs, marking jobs done, taking sales, sending client links. **No money amounts** |
| **Client** | A secret link or QR code for their order, or finding it with their phone number | Their own Order Room: progress, pictures, messages, "I've paid". **No amounts** |
| **Stranger** | Nothing | Can check whether a receipt is genuine (`check.html`). Nothing else |

## How it's enforced

The rules are in the **database**, not just the screens. Hiding a button is not security, because anyone can open the browser's developer tools. So:

1. **Every table is locked** (Row Level Security is on). Tables with money (`kt_invoices`, `kt_payments`, `kt_counters`) can only be read when `is_admin()` is true, which means the owner only.
2. **Nobody writes to tables directly.** Every change goes through a database function that checks who is asking first:
   - owner actions call `ws_need_owner()`
   - workshop actions check `ws_is_station()`
   - manager actions check the scrambled manager code with `ws_foreman_ok(pin)`
   - worker actions check the worker's sign-in token
3. **The workshop side never receives amounts.** Workshop and Order Room functions only return flags like "deposit confirmed" or "paid". The owner's invoice and receipt PDFs are made on her own phone and are not stored online.
4. **PINs and the manager code are scrambled** (bcrypt). Five wrong tries locks them for 5 minutes.
5. **Strangers can only call** the Order Room functions, the receipt check and the website's order functions. Each of these needs a long secret code to find anything.
6. **Client pictures** (`room-files` bucket) are public files under long random folder names. Only someone with the client's link can find them. Workshop photos (`kartech-photos`) are private.

## Check it yourself (do this after every database update)

Supabase → SQL Editor → New query → paste all of **`supabase/check-security.sql`** → Run.

It is read-only. It checks the rules, then **pretends to be a stranger, the workshop computer and the owner** and counts what each one can see. You get one table:

| Result | Meaning |
|---|---|
| **PASS** | Correct |
| **FAIL** | Stop. Fix it before real clients use the system. The *note* column says what is wrong |
| **CHECK** | Needs a person to look. For example, the Order Room pictures folder is public on purpose |

What it checks:

- every table is locked
- only the owner may read money tables
- nobody can write money tables directly
- strangers can only reach the allowed functions
- the photos bucket is private
- an owner account and a workshop account exist, and the workshop account is **not** also an owner
- a stranger sees 0 invoices, payments, orders, workers or website orders
- the workshop computer sees 0 invoices, payments or workers
- the owner sees every invoice

## Supabase settings to check by hand

These live in the Supabase dashboard, not in the code, so the check above can't see them:

- [ ] **Authentication → Sign In / Providers → Allow new users to sign up: OFF.** All accounts are made by hand.
- [ ] **Authentication → Users:** only the owner, the workshop computer and any website admins. Delete anything you don't recognise.
- [ ] **Project Settings → API Keys:** only the **publishable** key is in `js/config.js`. The **secret / service_role** key must never be in any file, chat or screenshot.
- [ ] The owner's password is strong and only she knows it. If the workshop password leaks, change it in Authentication → Users, then sign in again on the workshop computer.
- [ ] If the owner's phone is lost, change her password straight away.

## Found during the review (November 2026)

- **Fixed in update 25.** Three helper functions (`ws_task_names`, `ws_is_here`, `ws_attendance_track`) could be called by strangers. The worst they could show was worker names for a job ID, which a stranger couldn't know anyway. `update-25-lock-helpers.sql` closes them, and from now on it closes any non-client function that becomes open by accident. **Run it on the live project.**
- **Re-running old update files** can bring back older versions of functions. See the rules in [DATABASE.md](DATABASE.md).
- **Public sign-ups** should be off (see the list above). Even with them on, a self-made account cannot see money or change anything, because every function checks for the owner, the workshop computer, the manager code or a worker token. It's still one less door.
