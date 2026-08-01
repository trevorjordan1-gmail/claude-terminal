# Splashtop Cursor-Encoder Crash Guard — Design Spec

**Date:** 2026-07-31
**Status:** Approved (maintainer). Module authored and field-tested outside this
repo; integrated here.

## Purpose

Splashtop Streamer for Linux (≤ 3.8.0.0, the current release) has a
use-after-free race in `SRFeature`'s cursor-image encoder. A worker thread
PNG-encodes a cursor pixbuf while another thread replaces and destroys it; the
encode then reads a dead `GdkPixbuf` and the process dies with SIGSEGV in
`libgdk_pixbuf`, dropping every Splashtop session on the machine.

Since Splashtop is how the maintainer's techs reach these boxes at all, a
streamer that dies under ordinary use makes the whole remote-access story
unreliable. This module works the bug around until Splashtop ships a fix.

## The bug, as measured

Established by controlled repro on a test box, 2026-07-31:

- Displaying **one** animated cursor (the Yaru busy set: 60 frames at 16ms,
  cycled by the X server, one XFixes event per frame) crashed the streamer
  within two seconds. Reproducible at will, no browser involved.
- 671 rapid changes between **static** cursors, at up to 60 changes/sec, ran
  clean.

So the trigger is animation, not event rate — which is why making every cursor
file single-frame is a complete fix for that path rather than a mitigation.
Firefox is the practical trigger in normal use: GNOME's launch spinner and
Firefox's busy cursor over its own window are the only animated cursors one of
these boxes ever shows.

Separately, the race still fired rarely (roughly once per hour of active use)
on ordinary cursor churn with every file static. Minidump analysis showed the
identical cursor-encoder stack. No amount of trigger elimination closes that,
which is why guard 4 exists.

## The four guards

Each of the first three was added because its absence caused a real recurrence
during rollout — this is deployment history, not speculation.

1. **Staticize every animated cursor under `/usr/share/icons`**, installed via
   `dpkg-divert --add --rename --divert <file>.animated`. The parking at
   `*.animated` is what makes theme package upgrades land harmlessly instead of
   clobbering the static rebuild. The rebuild is pure-stdlib Python: an Xcursor
   file is a table of image chunks, an animation is several images sharing one
   nominal size, so keeping the first image per size yields the same art and
   hotspots with no frames.

   It must scan **every file in every theme**. Fixing only Yaru's four named
   busy cursors was tried and kept crashing. Verified on a stock 24.04 desktop:
   16 animated cursor files are present, and only four are the named Yaru ones —
   the rest are Yaru's `half-busy`, three legacy hash-named files, and animated
   cursors in the Adwaita, DMZ-Black, DMZ-White and redglass fallbacks.

2. **Republish Firefox's `.desktop` with `StartupNotify=false`** into
   `/usr/local/share/applications`, which precedes `/var/lib/snapd/desktop` in
   `XDG_DATA_DIRS`. Launching Firefox then never requests a busy cursor at all.
   Regenerated from the live snapd copy on every run so `Exec=` stays correct
   across snap refreshes.

3. **Repack and sideload `gtk-common-themes`.** Snap apps cannot see host
   themes: the GNOME runtime's `desktop-launch` hard-sets `XCURSOR_PATH` to
   snap-internal paths, and snap namespaces mount each squashfs directly. Host
   theme fixes, `~/.icons`, environment injection and bind mounts under `/snap`
   were each tested and none reach inside. Consuming snaps' mount namespaces
   are discarded afterwards so the change takes effect without a reboot.

4. **`LD_PRELOAD` shim on `SRStreamer.service`** that defers the destroying
   unref of pixbufs created through `gdk_pixbuf_new_from_data` (the cursor path)
   by a three-second grace period, so an encode can never race a destruction.
   This is the definitive guard; guards 1–3 remain worthwhile because they
   remove the deterministic 60-events/sec trigger and keep the cursor pipeline
   idle. A mutex-only design was tried first and cannot work — the pixbuf is
   destroyed before the encode begins, so serialising save-against-unref doesn't
   keep the object alive.

## Scope

The module skips entirely unless `splashtop-streamer` is installed. Every guard
exists only to keep Splashtop's `SRFeature` alive, so RustDesk boxes and
machines with no remote-access tool get zero changes — no diversions, no snap
sideload, no compiler.

There is precedent for a conditional core module: `45-hyperv-qol` runs only on
Hyper-V.

## Ordering: `# ct-after-extras`

Core modules run before extras, but `--with-splashtop` installs the streamer
*in* the extras pass. Left alone, a fresh box would skip the crash guard on the
very run that installed Splashtop, and the fix would land only on the next
bootstrap — leaving the streamer crashing in between.

Rather than a `next_step` telling the operator to run bootstrap twice, the
dispatcher gained a small general capability: a core module carrying
`# ct-after-extras` is deferred to the end of the run instead of executing in
lexical position. One bootstrap run now installs Splashtop and then guards it.

The trade-off is that such a module's number no longer reflects when it runs.
That's documented in the module contract and in the module's own header.

## Update safety

Nothing here becomes a time bomb when Splashtop updates. The shim wraps stable
public gdk-pixbuf/GObject symbols rather than Splashtop internals: on a fixed
streamer it is harmless, since deferring an object's destruction is always
legal; if a future streamer stops using gdk-pixbuf the wrappers are never
called; if the service is renamed the drop-in stops applying. Every failure mode
is fail-open to vanilla behaviour.

A version canary emits a NEXT STEPS line whenever the installed streamer is
newer than 3.8.0.0, so an update prompts re-testing and retirement instead of
passing silently. Retirement steps live in the module header.

Guard 4 rebuilds and restarts the streamer only when the shim source or drop-in
actually changed, so re-running bootstrap never drops a live Splashtop session.

## Known caveats

- **Live sessions need one logout.** Running X clients — gnome-shell above all —
  hold cursor objects built from the old animated files, and the X server keeps
  animating those until the client recreates them. The module raises a
  `next_step` saying so. Fresh builds that reboot after bootstrap never see it.
- **The sideloaded theme snap no longer auto-refreshes.** Acceptable for a theme
  pack that essentially never changes. A manual `snap refresh --amend` would
  bring animated cursors back until the next bootstrap run; the shim still
  prevents crashes in that window.
- **Guard 4 installs gcc** on Splashtop machines, via the same `apt_install`
  every module uses.

## verify.sh

Read-only checks in the existing `p/f/s` style, all skipped when
`splashtop-streamer` is absent so RustDesk boxes report SKIP rather than FAIL:
no animated cursors under `/usr/share/icons`; none in the theme snap (SKIP when
absent); at least one `.animated` dpkg diversion; the Firefox override present
with `StartupNotify=false` (SKIP when snap Firefox is absent); and the shim
wired into the service.

The shim check deviates from the handoff deliberately. The handoff proposed
`sudo grep` against `/proc/<pid>/maps`, but `verify.sh` is documented as
read-only *and sudo-free*. Reading a root process's maps needs root, so it
checks `systemctl show SRStreamer.service -p Environment` for the `LD_PRELOAD`
instead — same wiring, no privilege.

## Changes made during integration

The module was added essentially verbatim. Three edits:

1. A test machine's hostname appeared twice in the header comments. Removed
   under the repo's no-identifiers rule.
2. `ls … | head -1` for the theme snap replaced with a glob loop to clear
   shellcheck SC2012. Selection order is unchanged — the shell sorts too.
3. Added the `# ct-after-extras` marker and a header note explaining it.

## Out of scope

- Fixing the streamer itself. This is a workaround pending an upstream fix.
- Switching the fleet from snap Firefox to Mozilla's deb, which would make the
  whole snap-theme problem class disappear. That's a product decision touching
  dock pins and profile migration, and is the maintainer's call.
- Re-proving crash prevention in CI. It needs a Splashtop-registered machine and
  is already validated in production.
