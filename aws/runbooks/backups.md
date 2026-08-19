# Backups — nightly restic for every DCV system

Every terminal is disposable, but the work on it is not. A build box in
particular is where an engagement actually lives for weeks before the
customer's environment exists. So each machine backs its `/home` up nightly to
one restic repository of its own.

**Dormant by default.** A tenant with no `/asp/backup/config` parameter has no
backups and no failures — `backup-arm.sh` no-ops and says so. Creating the
parameter is what turns the capability on, the same shape as build boxes.

## Layout — one bucket per tenant, grouped by engagement

```
<backup-bucket>/
  <client>/          # engagement code, or the tenant's own client code
    <machine>/       # one restic repo per machine
```

`<client>` is the **`BuildFor` code for a build box** and the **tenant's
`CLIENT_CODE` for a normal terminal** — so on an operator tenant the operator's
own terminals collect under its own code and each engagement's workbenches sit
under theirs, while on a customer tenant everything naturally lands under that
customer. One prefix holds everything for one engagement, which is what makes
"purge when the customer is flying" a single, checkable operation.

The box cannot read its own tags (the desktop role has no `ec2:DescribeTags`
and the hostname is the private IP), so the portal writes `ASP_MACHINE_NAME`
and `ASP_BACKUP_CLIENT` into `/etc/asp-terminal.env` at launch.

A terminal provisioned before the portal wrote those falls back to its client
code from `ASP_CUSTOMER` and its **instance id** — deliberately not its
hostname, which is a private IP that AWS can hand to a later instance, quietly
pointing two terminals at one repo. To give such a box its readable name,
append the two lines to `/etc/asp-terminal.env` before arming it.

## Configure a tenant

`/asp/backup/config` — **SecureString**, JSON:

| Key | Meaning |
|---|---|
| `BACKUP_BUCKET` | bucket name |
| `BACKUP_ENDPOINT` | S3 endpoint — `https://s3.<region>.amazonaws.com`, or the S3-compatible one (Wasabi: `https://s3.<region>.wasabisys.com`) |
| `BACKUP_ACCESS_KEY` / `BACKUP_SECRET_KEY` | credentials for that bucket |
| `RESTIC_PASSWORD` | repo encryption password — **the one thing that cannot be regenerated** |
| `BACKUP_KEEP` | optional `restic forget` flags; default `--keep-daily 7 --keep-weekly 4 --keep-monthly 6` |

Credentials come from this parameter rather than the instance role on purpose:
the same script has to work against a customer's Wasabi bucket, where no AWS
role exists. On an AWS-backed tenant the key is an IAM user scoped to the one
bucket.

> **`RESTIC_PASSWORD` belongs in the credential vault before the first backup
> runs.** Lose it and every repo it protects is unreadable — restic has no
> recovery path. It is per tenant, not per machine.

Bucket hygiene: block all public access, default encryption on, and **no
versioning** — restic keeps its own history and `forget --prune` must be able
to delete, so versioning only accumulates cost.

### Retention vs. minimum storage duration

Set `BACKUP_KEEP` to match the **minimum storage duration the bucket bills**,
or pruning costs money and buys nothing.

Object stores that advertise no egress fees typically charge a minimum
retention instead: Wasabi bills pay-as-you-go objects for 90 days (30 on
reserved capacity) and applies a "Timed Deleted Storage" charge for the
remaining days when you delete sooner. The shipped default
(`--keep-daily 7 --keep-weekly 4 --keep-monthly 6`) makes `forget --prune`
repack and delete continuously, so on such a bucket **every prune bills for
storage we no longer have** — the worst of both: paying for the data and not
having it.

Where a minimum applies, keep at least that long — the storage is already paid
for, so the extra history is effectively free:

```
BACKUP_KEEP = --keep-daily 90 --keep-monthly 12    # 90-day minimum bucket
BACKUP_KEEP = --keep-daily 7 --keep-weekly 4 --keep-monthly 6   # plain S3
```

Restic deduplicates, so 90 dailies of a home directory that mostly sits still
cost far less than 90× the first snapshot.

New terminals arm themselves at build. To arm boxes that predate the config:

```
aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript \
  --parameters 'commands=["bash /opt/asp/backup-arm.sh"]'
```

`backup-arm.sh` is idempotent — re-running it re-reads config and re-arms.

## What runs

`asp-backup.timer` fires at 03:00 with up to 30 min of jitter, `Persistent=true`
— the part that matters on a hibernate-by-default fleet, because a box that was
paused overnight runs its missed backup shortly after it wakes. Each run backs
up `/home` (excluding caches, `node_modules`, virtualenvs and other regenerable
trees), then prunes to the retention window.

## Restore

Restic repos are self-describing; any machine with the repo URL, the key and
the password can read one.

```
export RESTIC_REPOSITORY=s3:<endpoint>/<bucket>/<client>/<machine>
export RESTIC_PASSWORD=... AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
restic snapshots
restic restore latest --target /tmp/restore          # whole home
restic restore latest --target /tmp/restore --include /home/build/work/notes.md
```

On the box itself the environment is already there: `set -a; . /etc/asp-backup.env`.

## Checks

- `systemctl list-timers asp-backup.timer` — next run, last run.
- `journalctl -u asp-backup.service -n 50` — last run's output.
- `/var/log/asp-backup-arm.log` — what happened at build.
- A repo that has never had a successful run has no `snapshots` output. Treat
  "armed" and "has a snapshot" as different claims; verify the second one.
