# Database guide

Everything the system needs in Supabase is in the `supabase/` folder. This guide says what each file is, what order to run them in, and how to keep a project up to date.

## The short version

| Situation | What to run |
|---|---|
| **Brand-new project** | `INSTALL-ALL.sql` (everything, in order) |
| **Existing project, new code pulled** | `which-updates.sql`, then each MISSING file, lowest number first |
| **Not sure what's installed** | `which-updates.sql` (read-only, changes nothing) |
| **Before going live / after any update** | `check-security.sql` and `../tests/business-rules.sql` |

Run every file the same way: Supabase → **SQL Editor → New query** → paste **all** of the file → **Run**.

## The files, in order

The system shares one Supabase project with the Kartech **website**. File `00` creates the few website pieces the workshop needs (`admins`, `is_admin()`, `orders`, `custom_requests`) **only if they are missing**, so on Kartech's real project it changes nothing.

| # | File | What it adds |
|---|---|---|
| 0 | `00-website-basics.sql` | website pieces the workshop relies on (skipped if the website is set up) |
| — | `setup-workshop.sql` | database setup |
| 1 | `update-1-website-link.sql` | website orders join the workshop + tap-your-name sign in |
| 2 | `update-2-materials.sql` | raw materials (store, giving out, theft checks) |
| 3 | `update-3-tools.sql` | tools (grinders, welders, drills…) evening check |
| 4 | `update-4-foreman.sql` | the foreman page on the workshop screen |
| 5 | `update-5-steps.sql` | workshop steps the owner can change |
| 6 | `update-6-attendance.sql` | who is here today + the owner can give a job to anyone |
| 7 | `update-7-checkin.sql` | morning check-in by the foreman + tools per trade |
| 8 | `update-8-history.sql` | History (owner app → History) |
| 9 | `update-9-edit-orders.sql` | pick who does each step + edit or delete an order |
| 10 | `update-10-kartech-items.sql` | Kartech's real tools and materials |
| 11 | `update-11-together.sql` | steps at the same time + pick people for later steps |
| 12 | `update-12-all.sql` | job alerts, deliveries, photos |
| 13 | `update-13-manager.sql` | "Foreman" is now called "Manager" |
| 14 | `update-14-order-pictures.sql` | pictures of what to make (workers see them) |
| 15 | `update-15-sales.sql` | the manager takes sales + quote requests in the app |
| 16 | `update-16-order-room.sql` | the Order Room (stage 1) |
| 17 | `update-17-client-links.sql` | the manager can send any client their Order Room link |
| 18 | `update-18-payments.sql` | invoice and payments, WITHOUT any money amounts |
| 19 | `update-19-fix-client-photos.sql` | fix "permission denied for table ws_orders" when a client |
| 20 | `update-20-find-my-order.sql` | a client finds their order with their phone number |
| 21 | `update-21-bin.sql` | the Bin 🗑 |
| 22 | `update-22-simple-assign.sql` | simple assigning: the owner can mark a step done |
| 23 | `update-23-invoices-receipts.sql` | invoices and official receipts (with amounts) |
| 24 | `update-24-manager-done.sql` | the manager can mark a worker's job done |
| 25 | `update-25-lock-helpers.sql` | close three small side doors (found by check-security.sql) |
| 26 | `update-26-shop-products.sql` | the owner runs the website shop from her app (products, prices, photos) |
| 27 | `update-27-relink-invoices.sql` | an order brought back from the Bin gets its invoice back |
| 28 | `update-28-messages.sql` | messages between the owner and each worker |
| 29 | `update-29-fabrics.sql` | fabrics and colours: a fabric list with metres, a fabric on each order, colours on shop products |
| 30 | `update-30-fabric-photos.sql` | a photo on each fabric |
| 31 | `update-31-order-lines.sql` | several items in one order (each with its own quantity and fabric) |
| 32 | `update-32-client-sees-order.sql` | the client sees what she ordered: items, fabric and design pictures (never prices) |

The order matters: each update builds on the ones before it. Updates 1 to 32 have been tested on a brand-new database, in this order, with no errors. All 54 business-rule tests and all security checks pass afterwards.

### Helper files (read-only, they change nothing)

| File | What it tells you |
|---|---|
| `which-updates.sql` | One row per update: **yes** or **MISSING** |
| `check-security.sql` | Who can see what. See [SECURITY.md](SECURITY.md) |
| `../tests/business-rules.sql` | 39 tests of the money and order rules. See [TESTING.md](TESTING.md) |

### Retired files

`old/ALL-UPDATES.sql` and `old/update-14-to-18-ALL.sql` were early shortcuts. **Do not run them.** They can put back older versions of functions. `INSTALL-ALL.sql` replaces them.

## Rules for database changes

1. **Never re-run a single old update on its own** (for example only `update-12`). Later updates replaced some of its functions, and re-running it would bring back the older versions. To repair a project, run `INSTALL-ALL.sql` from the top: it always ends on the newest version of everything.
2. **New change = new numbered file.** The next one is `update-29-….sql`. Never edit an update that has already been run on the live project.
3. Every update must be **safe to run twice** (`create or replace`, `if not exists`, `on conflict do nothing`).
4. Any function that changes data must start with a permission check:
   - owner only: `perform public.ws_need_owner();`
   - workshop computer: `ws_is_station()`
   - manager: `ws_foreman_ok(pin)`
   - worker: their sign-in token
5. End each new function with its permissions: `revoke all … from public, anon;` then `grant execute … to authenticated;`. Only Order Room and receipt-check functions may be open to strangers.
6. After adding a file:
   - rebuild `INSTALL-ALL.sql` by adding the new file to the end, with the same `FILE:` header as the others
   - add a row for the new update to `which-updates.sql`
   - add a row to the table above
   - run the tests and the security check

## Storage folders (buckets)

| Bucket | Made by | Public? | What's in it |
|---|---|---|---|
| `kartech-photos` | update 12 | **Private** | Job photos and pictures of what to make. Only the owner and workshop see them |
| `room-files` | update 16 | Public, under secret codes | Pictures shared with a client in their Order Room |
| `request-files` | the website | (website) | Photos customers attach to quote requests |
| `shop-photos` | update 26 | Public | Product photos for the website shop. Only the owner can add or remove them |

Invoices and receipts are **never stored** anywhere. The PDF is made on the owner's phone the moment she sends it.

## Main tables

| Table | Holds |
|---|---|
| `ws_orders` | Workshop orders: customer, item, deadline, payment status flags (no amounts) |
| `ws_tasks` | One row per step of an order: who is on it, waiting / working / done |
| `ws_workers` | Workers, trade, scrambled PIN, today's attendance |
| `ws_steps` | The workshop steps the owner can edit |
| `ws_materials`, `ws_tools`, `ws_moves` | Stock, tools and who took what |
| `ws_photos`, `ws_room_msgs` | Pictures and Order Room messages |
| `ws_log`, `ws_attendance` | History and news feed |
| `ws_bin` | Deleted orders, workers and pictures (30 days) |
| `kt_invoices`, `kt_payments`, `kt_counters` | **Money**: owner only, see SECURITY.md |
| `ws_settings` | Manager code (scrambled), M-Pesa number, business details |
| `ws_stations` | Which login is the workshop computer |
| `ws_messages` | Messages between the owner and each worker. Only the owner reads the table; a worker sees only their own, after signing in |
| `kt_products` | The website shop: name, public price, photos, category. Anyone can read visible products; only the owner can change them |
