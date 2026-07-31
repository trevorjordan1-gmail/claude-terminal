# Splashtop Extra + Suggested-Extras Mechanism — Design Spec

**Date:** 2026-07-31
**Status:** Approved (maintainer)

## Purpose

Field techs build these VMs in a Hyper-V console, which has no clipboard — every
character is typed by hand. That constraint drives everything here: the fewer
commands, and the shorter they are, the better. Splashtop is how a tech escapes
that console, so getting it installed and registered has to be near-frictionless.

It also has to stay optional. Not every site uses Splashtop; some use RustDesk.
So this ships as an opt-in extra behind its own flag, and the mechanism that
advertises it is generic enough that the next product is a module file and
nothing else.

This closes the long-standing "Splashtop automation" roadmap item, whose stated
blocker was the version-pinned download URL. See *Version pinning* below for why
that blocker turned out to be smaller than it looked.

## Why a flag, not a prompt in bootstrap

An earlier draft had `bootstrap.sh` ask every user whether they wanted Splashtop.
That was rejected: it puts a product-specific question in the dispatcher, it
doesn't generalise to a second product, and it erodes the property that
re-running bootstrap is an unattended upgrade path.

Instead the existing `--with-<extra>` mechanism carries it, and discoverability
comes from the run's own output. A core-only run now ends with:

```
══ NEXT STEPS ═══════════════════════════
  1. Run 'claude' once to log in to Claude Code, then re-run ./bootstrap.sh …
  2. Remote access (Splashtop): ./bootstrap.sh --with-splashtop
```

The hint points at the local `./bootstrap.sh`, not the curl URL — after a first
run the repo is already at `~/claude-terminal`, so that's both shorter to type
and avoids re-downloading. A tech who knows up front can do it in one pass with
`curl -fsSL https://get.wtfapps.net | bash -s -- --with-splashtop`.

## The suggested-extras mechanism

An extra opts in with a header line parallel to the existing `ct-desc`:

    # ct-suggest: <command>|<hint>

After the summary, `bootstrap.sh` prints `<hint>` as a next step when that extra
did **not** run this time *and* `<command>` is not on PATH. The command is the
already-installed probe, so a box that has Splashtop stops being nagged about it.
A value with no `|` is always suggested.

This is ~16 lines reusing the `sed -n 's/^# ct-desc: //p'` idiom `--list`
already uses. Adding RustDesk later is a new module file carrying its own
`ct-suggest:` line; the dispatcher never learns either product exists.

## Module behavior

`modules/extra/splashtop.sh` replaces the manual-instructions stub.

1. If `splashtop-streamer` is already installed, `ok` immediately without
   prompting or redeploying — this is what keeps `git pull && ./bootstrap.sh`
   unattended. Re-registering is a documented one-liner.
2. Resolve the deployment code from `$CT_SPLASHTOP_CODE`, else prompt. This
   happens *before* the download, so a run that can't get a code doesn't pull
   11MB first.
3. With no code and no terminal, `next_step` + `skip`. It never blocks.
4. Download the pinned tarball, unpack, install the `.deb` via `apt_install`.
   The package's own `postinst` symlinks `/usr/bin/splashtop-streamer` and
   starts `SRStreamer.service`.
5. `sudo splashtop-streamer deploy "$CODE"`, then
   `sudo splashtop-streamer config -auto_update=1`.
6. `ok`, noting separately if the service didn't come up.

Deploy runs under `sudo` deliberately. The package's polkit action for these
operations is `auth_admin_keep`, so invoking them as a normal user would raise
an authentication dialog instead of simply running. Root takes the branch in the
vendor's own `spt_main` that deploys and restarts the service directly.

`splashtop-streamer deploy` ends with `return $ret`, so a rejected code really
does surface as a non-zero exit and reaches `fail`. That was verified by reading
the shipped script, not assumed.

## The prompt exception

This is the first module in the repo that prompts, so `docs/DEVELOPMENT.md`'s
"never a prompt" rule gains one narrow exception: an extra the user explicitly
requested by its own `--with-` flag may prompt for input that is inherently
per-machine and secret, must read from `/dev/tty`, and must `skip` when it
can't. Core modules get no exception. The flag is the explicit intent the
original rule was protecting.

Two traps are documented because both fail silently:

- Under `curl | bash`, stdin is the pipe. A bare `read` consumes the script's
  own next line as its input — no prompt appears, and the consumed line never
  executes. Tested: the statement after `read` simply never ran.
- `[ -t 0 ]` is **false** under `curl | bash` even in a real console, so gating
  on it would skip the prompt exactly when it should appear. The correct gate is
  `( : </dev/tty ) 2>/dev/null`, which is true in a piped console and false with
  no controlling terminal at all.

Note that bootstrap was never fully unattended anyway — `sudo -v` has always
prompted on a first run. The property worth protecting is unattended *re-runs*,
which the already-installed check preserves.

## Version pinning

Splashtop publishes no "latest" URL. Their download host returns 403 for
directory listings, for unversioned filenames, and for versions that don't
exist — so a missing build is indistinguishable from a wrong guess. The public
downloads page doesn't carry the Linux link, and the only update path inside the
shipped binaries is a bare `/check_update` whose host is assembled at runtime
against their authenticated backend.

So the URL stays pinned, and two things make that cheap. The streamer updates
itself once `-auto_update=1` is set, so the pin only has to get the package on
the box once. And because the module lives in the repo, bumping it is a one-line
edit plus a push — no box needs touching. Linux builds are rare; 3.8.0.0 dates
from January 2026 and is still the only one published.

A stale pin fails with a message naming the file and variable to change, rather
than a bare curl error.

## verify.sh

Follows the existing "extras are reported only when artifacts exist" pattern:
when the package is installed, PASS if `SRStreamer.service` is active and FAIL
if it isn't. Nothing is printed when Splashtop was never installed.

## Docs

- README: the Splashtop section becomes four lines — the command, and what to
  type when asked. The extras table row is updated. Deliberately terse at the
  maintainer's request.
- `docs/DEVELOPMENT.md`: the module contract gains `ct-suggest:`; hard rule 7
  gains the prompt exception and both traps; the roadmap item is replaced with
  RustDesk.
- `CHANGELOG.md` entry (2026-07-31).

## Testing

- `bash -n` and dockerized shellcheck across all tracked scripts, finding-free.
- `--list` and `--help` smoke runs. `bootstrap.sh` itself is never run on the
  dev box.
- The suggestion loop was extracted from `bootstrap.sh` and unit-tested against
  fixture modules covering every branch: not-run-and-absent (suggested),
  command-present (suppressed), ran-this-time (suppressed), no `ct-suggest`
  line (ignored), and a value with no `|` (always suggested). Then run against
  the real modules directory with a sandboxed PATH, producing exactly the
  intended line.
- `read` behaviour under a pipe, and the `/dev/tty` gate across three
  environments (piped-under-a-pty, piped-with-no-pty, and fully detached), were
  verified before the module was written.
- Real-box validation is pending and is the remaining step.

## Out of scope

- **RustDesk.** The mechanism accommodates it; the module isn't written.
- Unattended provisioning beyond `CT_SPLASHTOP_CODE`, on-prem gateway deploys
  (`deploy GATEWAY CODE`), device naming, and any other `splashtop-streamer
  config` options.
- Adding Splashtop to `--all-extras`, which continues to exclude it.
