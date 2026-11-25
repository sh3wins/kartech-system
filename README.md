# Kartech Workshop System

A phone-first system that runs **Kartech Engineering's** metal workshop in Nairobi: orders, workers, steps, materials, tools, client updates, invoices and receipts. It is built from plain web pages and runs on any phone, tablet or computer, with nothing to install from an app store.

**Live:** https://sh3wins.github.io/kartech-system/

---

## The four screens

| Page | Who uses it | What it does |
|---|---|---|
| `owner.html` | **The owner**, on her phone or laptop | Today's dashboard with sales demand charts, the website shop (add products, photos and prices), orders (shop, website and manager orders kept apart), "Who's doing what", stock, workers, money (invoices, PDF receipts, balances), history, Bin, settings |
| `station.html` | **The shared workshop computer** | Workers tap their name and PIN to see only their own job and mark it finished. The **Manager** (behind a code) ticks attendance, hands out tools and materials, gives and changes jobs, marks jobs done, takes sales and sends clients their Order Room link or QR code |
| `room.html` | **Clients**, from a link or QR code | Their own **Order Room**: progress, pictures, messages, approving the design, "I've paid the deposit". Clients can also find their order by phone number |
| `check.html` | **Anyone** holding a Kartech receipt | Scanning the QR code on a receipt shows whether it is genuine |

`index.html` is the front door. It asks "Owner or Workshop?" once, then remembers the answer on that device.

## Who sees what (the most important rule)

| | Owner | Manager / workers | Client |
|---|:-:|:-:|:-:|
| Orders and steps | ✅ | ✅ (their part) | ✅ (their own order) |
| **Money amounts**: invoices, payments, balances, income | ✅ | ❌ never | ❌ only in the PDFs the owner sends |
| Payment status | ✅ | Only "Deposit confirmed" | "Paid ✓" |

This rule is enforced **inside the database**, not just hidden on screen. Even someone who opens the browser's developer tools on the workshop computer gets no amounts. See [`docs/SECURITY.md`](docs/SECURITY.md).

## How it's built

- **Front end:** plain HTML, CSS and JavaScript, with no framework and no build step. Each page loads its own file from `js/` and `css/`.
- **Back end:** [Supabase](https://supabase.com) (Postgres database, logins, file storage). The rules live in database functions (`supabase/*.sql`). The pages only call those functions.
- **PDFs and QR codes:** jsPDF 2.5.2 and qrcode-generator 1.4.4, saved inside the project in `js/vendor/` so they work even when outside websites are blocked.
- **Hosting:** GitHub Pages, from the `main` branch. Every `git push` updates the live site within a minute or two.
- **Installable:** `manifest.json` and `sw.js` let the owner "Add to Home screen" so it opens like an app.

The workshop system shares one Supabase project with the **Kartech website** (the shop). Website orders and quote requests flow straight into the owner's Orders.

## Folder map

```
kartech-system/
├── index.html, owner.html, station.html, room.html, check.html   the pages
├── js/
│   ├── config.js        Supabase address and public key, workshop settings
│   ├── owner.js         the owner app
│   ├── station.js       the workshop screen (workers + manager)
│   ├── kartech-pdf.js   invoice and receipt PDFs
│   ├── qrcard.js        QR code pictures
│   ├── voice-type.js    voice typing for the owner
│   └── vendor/          jsPDF and QR libraries (do not edit)
├── css/                 styles for each page
├── supabase/            every database file, see docs/DATABASE.md
│   ├── INSTALL-ALL.sql      everything in one file, in order
│   ├── which-updates.sql    shows which updates a project already has
│   ├── check-security.sql   checks who can see what
│   └── old/                 retired files, do not use
├── tests/
│   └── business-rules.sql   35 tests for money, orders and permissions
└── docs/                SETUP, DATABASE, SECURITY, TESTING guides
```

## Getting started

- **New setup** (new Supabase project or a fresh install): follow [`docs/SETUP.md`](docs/SETUP.md).
- **Existing project, after pulling new code:** run `supabase/which-updates.sql` in Supabase. If anything says MISSING, run that file (see [`docs/DATABASE.md`](docs/DATABASE.md)).

## Before every release

1. Run `supabase/which-updates.sql`. Every row should say **yes**.
2. Run `tests/business-rules.sql`. Every row should say **PASS**.
3. Run `supabase/check-security.sql`. Every row should say **PASS**.
4. Preview the screens (owner, workshop, Order Room) before pushing.
5. After pushing, run `git status` (it should say *nothing to commit*) and hard-refresh the live site with **Ctrl + Shift + R**.

Details are in [`docs/TESTING.md`](docs/TESTING.md).

## Known limits

- The owner's alarm sound only works while the app is open. SMS and phone-call alerts would need an SMS service (for example Africa's Talking), which is not connected yet.
- Free Supabase projects pause after about a week with no use. Daily use keeps them awake.
- Client pictures in the Order Room are stored under long secret links (see SECURITY). Invoices and receipts are never stored there.
- Payments are recorded by the owner after she sees the M-Pesa message. There is no automatic M-Pesa (Daraja) connection yet.

---

Built by **Aurelia Mwangi** for Kartech Engineering, Nairobi.
