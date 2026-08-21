# Spending limits

Every tenant gets a monthly limit, sized from what that tenant actually costs.
Dormant by default: no `/asp/budget/config` parameter, no budget, no failure.

```
/asp/budget/config   (String)
{ "ALERT_EMAIL": "ops@example.com", "HOURS_PER_TERMINAL": "25", "HEADROOM_PCT": "30" }
```

Then `budget-set.sh`. Re-run it monthly (or after adding terminals) — it is
idempotent and re-sizes to current reality.

## How the number is chosen

1. **The tenant's own billed history** — the highest of the last three complete
   months. The honest worst case, and it needs no assumptions.
2. **A model**, for a tenant too new to have a full month: the measured rate
   card × the terminals that actually exist (counted from `Role=desktop`, so it
   cannot drift from the fleet) × expected hours.

The larger of the two, plus headroom. Headroom is what stops a normal month
paging anybody; 30% is the default.

## Scope it or it is meaningless

Both the sizing query and the budget itself are **filtered to the platform's
region**. This is not a detail — it is the whole difference between a limit and
a nuisance:

- Sized unscoped, the first run of this script asked for **$591/month** on a
  tenant whose platform costs ~$93, because a five-month-old $454 month of
  unrelated spend was still in range.
- Budgeted unscoped, it then reported **96% consumed on creation** — domains and
  an unrelated instance counted as terminal spend — before the platform had spent
  $31.

On an operator tenant the account holds more than this platform. On a
customer-owned tenant it usually does not, but the filter is correct either way,
and the two numbers must be scoped identically or the percentage is fiction.

## These alert. They do not stop anything.

80% and 100% of actual, 120% of forecast, by email.

**Deliberately no automatic shutdown.** AWS budget actions *can* stop EC2
instances, and pointing that at terminals would end someone's session mid-work
to save a few dollars — a worse outcome than the overspend, and it would land on
whoever happened to be working rather than whoever caused the cost.

If a tenant wants enforcement rather than notification, put it on
**`ec2:RunInstances`** — a budget action attaching a deny policy stops *new*
terminals from being created while leaving running ones alone. That caps growth,
which is what actually runs away, and it fails safe.

## What to look at when it fires

In order of likelihood:

1. **Egress.** The only line with no ceiling. A terminal streaming video all day
   moves several times the measured ~1.74 GB/hour. Check
   `DataTransfer-Out-Bytes` before anything else.
2. **A terminal that stopped hibernating.** Check for a keep-awake tag or an
   idle-watchdog override; an always-on desktop costs roughly 30× a lightly used
   one.
3. **Provisioned gp3 throughput.** 250 MB/s costs $5/volume/month above the free
   125. At light usage that is more than the terminal's own compute — the first
   thing to reconsider on a fleet that is mostly idle.
4. **Orphaned volumes.** A terminated terminal whose volume was not deleted bills
   $4/month per 50 GB forever, attached to nothing.
