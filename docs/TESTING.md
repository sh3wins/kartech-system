# Testing guide

There are two kinds of checks: **automatic tests** that run in Supabase in a few seconds, and a **screen check** done by a person before pushing.

## 1. Automatic tests: `tests/business-rules.sql`

**When:** after every database update, and before telling the owner something is live.

**How:** Supabase → SQL Editor → New query → paste **all** of `tests/business-rules.sql` → **Run**. You get one table. Every row should say **PASS**.

**Is it safe on the live project?** Yes. The test makes a pretend order for "TEST CUSTOMER", then **undoes everything at the end**: no order, invoice, receipt or message is kept, and no client is contacted. If the project has no owner or workshop account yet, it makes pretend ones for the test and removes them too.

### What the 35 tests cover

**Orders**
- the owner can create an order
- a new order waits on hold for the deposit
- no worker gets the job before a deposit

**Invoices**
- the total is worked out correctly
- the number looks like `INV-2026-0001`
- bad lines (quantity 0) are refused

**Payments**
- more than the balance is refused
- M-Pesa needs its code
- the same M-Pesa code can't be used twice
- a part payment shows the right balance
- the first payment starts the work
- paying the rest makes the order fully paid
- only the newest receipt can be cancelled
- cancelling takes back "fully paid"

**Delivery**
- an order cannot be delivered before it is fully paid

**Receipt check**
- the genuine check finds a real receipt and says no to a made-up code

**Clients**
- the Order Room opens with the right link
- a wrong link shows nothing
- **the Order Room contains no money amounts**

**Workshop computer**
- it can't record payments, make invoices or add orders as the owner
- it sees 0 invoices
- a wrong manager code is refused

**Strangers**
- they can't record payments or delete orders

**Shop products**
- strangers and the workshop computer can't change the shop
- the owner can add a product with a price
- a hidden product doesn't show on the website

**Bin**
- a deleted order leaves the list, goes to the Bin and can be brought back

**If a test says FAIL:** read its *note* column, which says what happened. Don't push or announce the change until it passes. A FAIL called *"The tests stopped early"* usually means a database update is missing, so run `supabase/which-updates.sql`.

### Adding a test

Each test is a few lines inside `pg_temp.kartech_tests()`:

```sql
begin
  perform public.some_function(...);                         -- try the thing
  res := res || 'FAIL|What should be true|it was allowed'::text;
exception when others then
  res := res || ('PASS|What should be true|' || sqlerrm);    -- it was refused, good
end;
```

or, to check a value:

```sql
res := res || format('%s|Test name|%s', case when <condition> then 'PASS' else 'FAIL' end, <what you saw>);
```

Run the file on a broken copy once, to make sure your new test can actually FAIL.

## 2. Security check: `supabase/check-security.sql`

Same way. Every row PASS (or CHECK with an explanation). See [SECURITY.md](SECURITY.md).

## 3. Screen check (before every push)

Preview first, then push. Open each screen on a **laptop** and on a **phone** (or the browser's phone view, F12 → phone icon):

- [ ] **Owner:** dashboard loads, add an order, open it, make an invoice, record a payment, send the PDF
- [ ] **Workshop:** a worker signs in with their PIN and sees their job. Manager → code → tap a worker → Mark job done
- [ ] **Order Room:** open a client link, check progress and pictures, and that **no amounts** show
- [ ] **Receipt check:** scan a receipt's QR code and see "genuine"
- [ ] No red errors in the browser console (F12 → Console)

## 4. After pushing

1. `git status` should say *On branch main … nothing to commit, working tree clean*.
2. Wait 1–2 minutes for GitHub Pages.
3. Hard-refresh with **Ctrl + Shift + R**. For the installed app, close it fully and reopen.
4. Quickly repeat the screen check on the live site.
