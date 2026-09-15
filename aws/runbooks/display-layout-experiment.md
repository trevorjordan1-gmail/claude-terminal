# Display layout: the "4 screens" root cause and the stored-config experiment

Tracker: #43 (follow-up to #42, #28, #20). For an agent with SSM access to a
**free** terminal (nobody connected, no Claude job running). ~15 minutes.
Everything here is reversible: delete one file, restart gnome-shell.

> **Result (2026-09-15, run on a real build box — details on #43): every check passed
> and this SHIPPED.** Connector names are `VNC-output-0..3` (not `VNC-0..3`), the rate
> is `59.963`, there is **no** `hotplug_mode_update` property, `XDG_CONFIG_DIRS` is unset
> (glib default, so `/etc/xdg` is read), a guard-off A/B reproduced the four heads with
> the file moved aside and one head with it present, a fresh session logged
> `corrections=0`, and a client resize moved the head to 2672x1544 without snapping back.
> Shipped form: `aws/scripts/session-monitors-xml.sh`, run synchronously by
> `dcvsessioninit` right after the #20 pre-mode, writes the session user's
> `~/.config/monitors.xml` from the live `xrandr --query` (real connector set, the extras
> in `<disabled>`) — generated per box because the lookup key is the full output set.
> The #42/#47 guard stays as the backstop. This file remains the re-verification
> procedure; the XML below now carries the real names.

## Why the four heads keep coming back (mutter gnome-46, Ubuntu 24.04)

Read from mutter's source, not observed — function names so it can be re-checked.

- At gnome-shell start `meta_monitor_manager_ensure_configured` picks a layout in
  this order: **stored** `monitors.xml` → "suggested" (needs RandR `suggested X/Y`
  props; Xdcv has none) → previous in-memory config (none yet) → **linear**.
- It **never considers what the X server already has**. Linear enables every
  output whose RandR connection is not `Disconnected` (Xdcv reports all four as
  connected) at its "preferred" mode, side by side. In the xrandr backend
  "preferred" is simply **the first mode in the output's list**; an
  `xrandr --addmode`d 1920x1080 lists after the driver's 800x600, so it is not
  preferred even on the first output.
- Hence 4×800x600 is the guaranteed outcome of every gnome-shell start. The #20
  pre-mode, the `--off` collapse and the portal's Connect-time layout cannot
  survive it. **Any later gnome-shell restart** (paint-probe TERM, crash →
  `Restart=always`) replays the same default; the #42 guard now re-arms on that
  restart (#47), but a stored layout would make the replay itself harmless.
- At runtime (`meta_monitor_manager_xrandr_handle_xevent`) an external RandR
  change is accepted as-is **unless** the server bumped `configTimestamp`, which
  only mode-LIST changes do (`RROutputSetModes`, `--addmode`); then the decision
  above re-runs. Whether dcvagent's client-size mode bumps it is unknown — step 6.

mutter's native "never enable these" mechanism is the `<disabled>` list in a
stored `monitors.xml`. That is what this experiment tests.

## 0. Pick a box and confirm it is free

```bash
sudo dcv list-sessions                       # note <sid> and the owner <user>
sudo dcv list-connections <sid>              # must be empty
sudo /opt/asp/idle-probe.sh                  # conns 0, no claude ticks
```

## 1. Get the session's DISPLAY and XAUTHORITY

```bash
PID=$(pgrep -u <user> -x gnome-shell | head -1)
sudo cat /proc/$PID/environ | tr '\0' '\n' | grep -E '^(DISPLAY|XAUTHORITY|XDG_CONFIG_DIRS)='
```

Record `XDG_CONFIG_DIRS` too — it decides whether a system-wide
`/etc/xdg/monitors.xml` would be read (step 8). Every `xrandr`/`gdbus` below runs
as the session user with those two variables exported:

```bash
alias asu='sudo -u <user> env DISPLAY=<display> XAUTHORITY=<xauth>'
```

## 2. Capture the facts the analysis guessed at

```bash
asu xrandr --query --prop > /var/tmp/xrandr-prop.txt        # /tmp is private to the SSM snap
asu gdbus call --session --dest org.gnome.Mutter.DisplayConfig \
  --object-path /org/gnome/Mutter/DisplayConfig \
  --method org.gnome.Mutter.DisplayConfig.GetCurrentState > /var/tmp/mutter-state.txt
```

From `xrandr-prop.txt`: the **output names** (`VNC-output-0..3` on Xdcv — the XML below
uses them; confirm on the box), each output's connection state, and whether any output carries a
**`hotplug_mode_update`** property. If it does, mutter uses a stored config only
at startup and never re-applies it at runtime — the best case for us.

From `mutter-state.txt`: the mode id for the 1080p mode, `1920x1080@<rate>`. The
`<rate>` in the XML must be within 0.001 of that number. For the #20 modeline
(`173.00 1920 2048 2248 2576 1080 1083 1088 1120`) it is **59.963**. If the box
has no 1920x1080 mode at all, run the #20 pre-mode lines from
`/etc/dcv/dcvsessioninit` first.

## 3. Install the stored config for the session user

```bash
sudo -u <user> mkdir -p /home/<user>/.config
sudo -u <user> tee /home/<user>/.config/monitors.xml >/dev/null <<'XML'
<monitors version="2">
  <configuration>
    <logicalmonitor>
      <x>0</x><y>0</y><scale>1</scale><primary>yes</primary>
      <monitor>
        <monitorspec>
          <connector>VNC-output-0</connector>
          <vendor>unknown</vendor><product>unknown</product><serial>unknown</serial>
        </monitorspec>
        <mode><width>1920</width><height>1080</height><rate>59.963</rate></mode>
      </monitor>
    </logicalmonitor>
    <disabled>
      <monitorspec><connector>VNC-output-1</connector><vendor>unknown</vendor><product>unknown</product><serial>unknown</serial></monitorspec>
      <monitorspec><connector>VNC-output-2</connector><vendor>unknown</vendor><product>unknown</product><serial>unknown</serial></monitorspec>
      <monitorspec><connector>VNC-output-3</connector><vendor>unknown</vendor><product>unknown</product><serial>unknown</serial></monitorspec>
    </disabled>
  </configuration>
</monitors>
XML
```

Rules that decide whether mutter accepts it (from `meta-monitor-config-store.c`):

- A monitor without EDID is matched on **connector + vendor/product/serial all
  literally `unknown`**, exact string match. Wrong connector name = no match =
  silently ignored (falls through to linear, i.e. today's behaviour).
- `<rate>` is mandatory and must be > 0; a malformed file drops **every** stored
  config with `Failed to read monitors config file` in the journal.
- The stored config must name **all** outputs present (enabled + disabled) —
  the lookup key is the full set.

## 4. Restart gnome-shell in place and check

```bash
sudo kill -TERM $(pgrep -u <user> -x gnome-shell)    # org.gnome.Shell@x11 is Restart=always
sleep 10
asu xrandr --query | head -8
sudo journalctl --since -2min | grep -iE 'monitors config|stored monitor|asp-layout-guard|asp-paint-probe'
```

Pass: one 1920x1080 head, the other outputs `connected` but with no geometry,
no `Failed to use stored monitor configuration` line. Fail: four 800x600 heads
or that journal line → recheck names and rate (step 2), fix the file, repeat.

## 5. Fresh session

```bash
sudo dcv close-session <sid>
```

Connect from the portal with the **native** client. Expect the desktop to come
up single-head from the first frame, and afterwards:

```bash
sudo journalctl -t asp-layout-guard --since -5min      # done: corrections=0
sudo grep -iE 'randr|layout|mode' /var/log/dcv/server.log | tail -30
```

## 6. Resize — the check that decides how this ships

With the native client still connected: resize the window to three different
sizes, wait ~5 s each, then disconnect and reconnect (portal Connect fires
`set-display-layout 1920x1080` — that reset is expected).

- Head follows the window each time → the stored config does not fight
  dcvagent. **Ship it (step 8).**
- Head snaps back to 1920x1080 on its own after a resize → dcvagent's mode
  change bumps `configTimestamp` and mutter re-applies the stored config. The
  file is then **startup-only** in value; report it, do not ship as is.

## 7. Revert (if anything is worse than before)

```bash
sudo rm /home/<user>/.config/monitors.xml
sudo kill -TERM $(pgrep -u <user> -x gnome-shell)
```

## 8. What to report on #43, and what ships if it passes

Paste: the output names and connection lines, whether `hotplug_mode_update`
exists, the `1920x1080@rate` id, the step-4 journal lines, the step-6 result,
and `XDG_CONFIG_DIRS`.

**What shipped (steps 4–6 passed 2026-09-15):** not a fixed file under `/etc/xdg`
but `session-monitors-xml.sh`, which `dcvsessioninit` runs synchronously after the
#20 pre-mode: it reads the live `xrandr --query`, takes the first connected output as
the primary at `1920x1080_60` (rate derived from the same modeline), puts every other
connected output in `<disabled>`, and writes `~/.config/monitors.xml` atomically —
only when the content changed, and never when the primary lacks the 1080p mode
(mutter would reject the file whole). Per-session generation is what makes the
connector set — the lookup key — correct on every box; a fixed four-output file would
silently fall through to linear on a box with a different head count. `/etc/xdg` is
proven to work too (row E) and remains an option if a system-wide file is ever wanted.
Journal tag `asp-monitors-xml`: `wrote …` on the first session, `unchanged …` after.
The #42/#47 guard stays as the backstop.
