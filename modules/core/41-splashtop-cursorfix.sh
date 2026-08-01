# shellcheck shell=bash
# ct-desc: Splashtop crash guard — static cursors (host + snap), no Firefox launch spinner, pixbuf race shim
# ct-after-extras
#
# Deferred to the end of the run (see bootstrap.sh): the gate below needs
# splashtop-streamer, which --with-splashtop installs during the extras pass.
# Without the deferral a fresh box would skip this on the very run that
# installed Splashtop, leaving the streamer crashing until the next bootstrap.
#
# Splashtop Streamer for Linux (<= 3.8.0.0, latest as of Jul 2026) has a
# use-after-free race in SRFeature's cursor-image encoder. It is triggered
# SPECIFICALLY by animated X cursors: the server cycles their frames (Yaru's
# busy set: 60 frames at 16ms) and each frame fires an XFixes cursor event the
# streamer must fetch and PNG-encode; within seconds SRFeature dies with
# SIGSEGV in libgdk_pixbuf and every Splashtop session drops. Measured on
# a test box, 2026-07-31: one animated cursor crashed the streamer in 2s, while
# 671 rapid changes between STATIC cursors (up to 60/s) ran clean — so making
# every cursor file single-frame is a complete fix, not a mitigation. Firefox
# is the practical trigger (GNOME launch spinner, busy cursor over its window).
#
# Three guards, all harmless on machines without Splashtop:
#   1. Rebuild EVERY animated cursor under /usr/share/icons as a static
#      single-frame file, installed via dpkg-divert (originals parked at
#      *.animated; survives theme package upgrades). Scanning all themes and
#      all files matters: besides Yaru's watch/progress/left_ptr_watch/wait
#      there are legacy hash-named cursors and half-busy, plus animated
#      cursors in fallback themes (Adwaita, DMZ-*, redglass) — a first
#      deployment that fixed only the four named Yaru cursors kept crashing.
#   2. Republish Firefox's .desktop with StartupNotify=false from
#      /usr/local/share/applications (which precedes /var/lib/snapd/desktop in
#      XDG_DATA_DIRS), so launching Firefox never requests a busy cursor at all.
#   3. Repack the gtk-common-themes content snap with every animated cursor
#      staticized and sideload it. Snap apps do NOT see the host theme: the
#      GNOME runtime's desktop-launch hard-sets XCURSOR_PATH to snap-internal
#      paths, and snap namespaces mount each squashfs directly, so host theme
#      fixes, ~/.icons, env injection, and bind mounts under /snap all fail to
#      reach them (each verified). Repacking the content snap is
#      the one clean route. Sideloaded snaps don't auto-refresh from the store
#      — fine for a theme pack that essentially never changes; a manual
#      `snap refresh gtk-common-themes --amend` would bring the animations
#      (and the crashes) back until bootstrap re-runs this module.
#
#   4. Neutralize the race itself: an LD_PRELOAD shim on SRStreamer.service
#      defers the destroying unref of every pixbuf created through
#      gdk_pixbuf_new_from_data (the cursor path) by a 3s grace period, so an
#      encode can never race a destruction. This is the definitive guard: the
#      race also fires (rarely, probabilistically) on ordinary static-cursor
#      churn from normal desktop use, which no amount of theme fixing can
#      remove. Guards 1-3 remain worthwhile: they remove the deterministic
#      60-events/sec trigger and keep the streamer's cursor pipeline idle.
#
# Scope: the module SKIPs entirely unless splashtop-streamer is installed —
# RustDesk/other remote-access machines never hit this bug and get no changes.
#
# Update safety (why this is not a time bomb when Splashtop updates):
#   - The shim wraps stable public gdk-pixbuf/GObject symbols, not Splashtop
#     internals. On a fixed future streamer it is harmless (deferring an
#     object's destruction is always legal); if a future streamer stops using
#     gdk-pixbuf the wrappers are simply never called; if the service is
#     renamed the drop-in stops applying. Every failure mode is fail-open to
#     vanilla behavior — never breakage.
#   - The dpkg-diverts survive theme package upgrades by design.
#   - The sideloaded gtk-common-themes pins (sideloads don't auto-refresh);
#     if someone manually refreshes it, animated cursors return but the shim
#     still prevents crashes. The guards back each other up.
#   - A version canary below emits a NEXT STEPS line whenever the installed
#     streamer is newer than 3.8.0.0, so an update prompts re-testing and
#     retirement instead of passing silently.
#
# On a machine with a LIVE desktop session, running X clients (gnome-shell in
# particular) still hold cursor objects built from the old animated files; the
# X server keeps animating those until the client recreates them. Hence the
# next_step below: log out/in (or reboot) once after first convergence. Fresh
# builds that reboot after bootstrap are covered automatically.
#
# Retire this module once Splashtop ships a streamer with the race fixed:
#   dpkg-divert --list | awk '/\.animated$/ {print $NF}' shows every divert;
#   for each: sudo rm -f <file> && sudo dpkg-divert --remove --rename <file>
#   sudo rm -f /usr/local/share/applications/firefox_firefox.desktop
#   sudo snap refresh gtk-common-themes --amend --stable
#   sudo rm -f /etc/systemd/system/SRStreamer.service.d/pixbuf-shim.conf \
#              /usr/local/lib/splashtop-pixbuf-shim.so /usr/local/src/splashtop-pixbuf-shim.c
#   sudo systemctl daemon-reload && sudo systemctl try-restart SRStreamer

# Every guard exists only to keep Splashtop's SRFeature alive; machines using
# RustDesk or nothing at all get no changes.
pkg_installed splashtop-streamer || skip "no Splashtop streamer on this machine"
[ -d /usr/share/icons ] || skip "no /usr/share/icons on this machine"
have python3 || fail "python3 is required to rebuild cursor files"

# Xcursor files are a toc of image chunks; an animation is simply several
# images sharing one nominal size. Keeping only the first image per size turns
# an animated cursor into a static one — same art, same hotspots, no frames.
# Pure stdlib so the module needs no PIL/xcursorgen.
#   check <file>        exit 0 iff static or not an Xcursor file; 1 if animated
#   fix <file> <out>    write a static rebuild of <file> to <out>
#   check-dir <dir>     exit 0 iff no animated Xcursor under <dir>/*/cursors/
#   fix-dir <dir>       staticize every animated Xcursor under <dir> in place
# *.animated files (diversion parking) are ignored in the dir modes.
CURSOR_PY="$CT_TMP/static-cursor.py"
cat > "$CURSOR_PY" <<'PY'
import struct, sys, os, glob

IMG = 0xFFFD0002

def parse(path):
    data = open(path, 'rb').read()
    if data[:4] != b'Xcur':
        return None
    _, _, version, ntoc = struct.unpack_from('<4sIII', data, 0)
    toc = [struct.unpack_from('<III', data, 16 + i * 12) for i in range(ntoc)]
    return data, version, toc

def survivors(toc):
    seen, keep = set(), []
    for typ, sub, pos in toc:
        if typ == IMG:
            if sub in seen:
                continue
            seen.add(sub)
        keep.append((typ, sub, pos))
    return keep

def rebuild(data, version, keep, out_path):
    def chunk_len(typ, pos):
        if typ == IMG:
            w, h = struct.unpack_from('<II', data, pos + 16)
            return 36 + w * h * 4
        return 20 + struct.unpack_from('<I', data, pos + 16)[0]
    out, chunks = bytearray(), []
    off = 16 + 12 * len(keep)
    out += struct.pack('<4sIII', b'Xcur', 16, version, len(keep))
    for typ, sub, pos in keep:
        n = chunk_len(typ, pos)
        out += struct.pack('<III', typ, sub, off)
        chunks.append(data[pos:pos + n])
        off += n
    for c in chunks:
        out += c
    open(out_path, 'wb').write(bytes(out))

mode = sys.argv[1]
if mode == 'check':
    parsed = parse(sys.argv[2])
    if parsed is None:
        sys.exit(0)
    data, version, toc = parsed
    sys.exit(0 if len(survivors(toc)) == len(toc) else 1)
elif mode == 'fix':
    parsed = parse(sys.argv[2])
    assert parsed, f'{sys.argv[2]} is not an Xcursor file'
    data, version, toc = parsed
    rebuild(data, version, survivors(toc), sys.argv[3])
elif mode in ('check-dir', 'fix-dir'):
    animated = 0
    for p in glob.glob(os.path.join(sys.argv[2], '*', 'cursors', '*')):
        if not os.path.isfile(p) or os.path.islink(p) or p.endswith('.animated'):
            continue
        parsed = parse(p)
        if not parsed:
            continue
        data, version, toc = parsed
        keep = survivors(toc)
        if len(keep) == len(toc):
            continue
        animated += 1
        if mode == 'fix-dir':
            rebuild(data, version, keep, p)
    if mode == 'check-dir':
        sys.exit(1 if animated else 0)
    print(f'staticized {animated} animated cursor files')
PY

CHANGED=0

# ---- guard 1: every animated cursor in every host theme -----------------------
for f in /usr/share/icons/*/cursors/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    case "$f" in *.animated) continue ;; esac
    python3 "$CURSOR_PY" check "$f" && continue     # static or not an Xcursor
    python3 "$CURSOR_PY" fix "$f" "$CT_TMP/cursor.static" \
        || fail "could not rebuild $f as a static cursor"
    # --rename parks the package's animated original at $f.animated, where
    # future theme package upgrades will keep landing instead of clobbering ours.
    sudo dpkg-divert --add --rename --divert "$f.animated" "$f" >/dev/null \
        || fail "dpkg-divert failed for $f"
    sudo install -m 0644 -o root -g root "$CT_TMP/cursor.static" "$f" \
        || fail "could not install static $f"
    CHANGED=1
done
python3 "$CURSOR_PY" check-dir /usr/share/icons \
    || fail "animated cursors remain under /usr/share/icons"

# ---- guard 2: Firefox launch spinner ------------------------------------------
# Launching Firefox is what displays the spinner, so stop the launch from
# requesting one. A copy in /usr/local/share/applications shadows the
# snap-generated file (XDG_DATA_DIRS order) and survives snap refreshes; it is
# regenerated from the live snap copy on every run so Exec= etc. stay current.
FF_SRC=/var/lib/snapd/desktop/applications/firefox_firefox.desktop
FF_DST=/usr/local/share/applications/firefox_firefox.desktop
if [ -e "$FF_SRC" ]; then
    sudo install -d -m 0755 /usr/local/share/applications
    sed 's/^StartupNotify=true$/StartupNotify=false/' "$FF_SRC" \
        | sudo tee "$FF_DST" >/dev/null || fail "could not write $FF_DST"
    have update-desktop-database && sudo update-desktop-database /usr/local/share/applications 2>/dev/null
fi

# ---- guard 3: cursors inside the snap world ------------------------------------
GCT_ICONS=/snap/gtk-common-themes/current/share/icons
if [ -d "$GCT_ICONS" ] && ! python3 "$CURSOR_PY" check-dir "$GCT_ICONS"; then
    log "repacking gtk-common-themes with static cursors (first run only, ~2 min)"
    have unsquashfs || apt_install squashfs-tools
    # Glob rather than ls (SC2012); same selection, since the shell sorts too.
    SNAPFILE=""
    for s in /var/lib/snapd/snaps/gtk-common-themes_*.snap; do
        if [ -e "$s" ]; then SNAPFILE="$s"; break; fi
    done
    [ -n "$SNAPFILE" ] || fail "cannot find the gtk-common-themes snap file"
    rm -rf "$CT_TMP/gct"
    sudo unsquashfs -q -d "$CT_TMP/gct" "$SNAPFILE" >/dev/null 2>&1 \
        || fail "unsquashfs failed on $SNAPFILE"
    sudo python3 "$CURSOR_PY" fix-dir "$CT_TMP/gct/share/icons" \
        || fail "could not staticize cursors in the unpacked snap"
    (cd "$CT_TMP" && sudo snap pack gct --filename gct-static.snap >/dev/null) \
        || fail "snap pack failed"
    sudo snap install --dangerous "$CT_TMP/gct-static.snap" >/dev/null \
        || fail "could not sideload the repacked gtk-common-themes"
    # apps keep their existing mount namespace until it is discarded; rebuild
    # it for every snap consuming the themes so the fix is live immediately
    snap connections gtk-common-themes 2>/dev/null \
        | awk 'NR>1 {split($2,a,":"); if (a[1] != "" && a[1] != "-") print a[1]}' \
        | sort -u | while read -r s; do
            sudo /usr/lib/snapd/snap-discard-ns "$s" 2>/dev/null || true
        done
    python3 "$CURSOR_PY" check-dir "$GCT_ICONS" \
        || fail "gtk-common-themes still has animated cursors after repack"
    CHANGED=1
fi


# ---- guard 4: neutralize the race itself (LD_PRELOAD shim) ---------------------
# Only meaningful where the streamer exists; everything above is theme hygiene,
# this one patches the crash out of the running process. Rebuilds and restarts
# the streamer ONLY when the shim source changed, so bootstrap re-runs never
# drop an active Splashtop session.
SHIM_SRC_DST=/usr/local/src/splashtop-pixbuf-shim.c
SHIM_SO=/usr/local/lib/splashtop-pixbuf-shim.so
SHIM_DROPIN=/etc/systemd/system/SRStreamer.service.d/pixbuf-shim.conf
if [ -e /etc/systemd/system/SRStreamer.service ] || systemctl cat SRStreamer.service >/dev/null 2>&1; then
    cat > "$CT_TMP/pixbuf-shim.c" <<'CEOF'
/* splashtop-pixbuf-shim v2: work around a use-after-free race in Splashtop
 * SRFeature's cursor encoder (<= 3.8.0.0). A worker thread PNG-encodes a
 * cursor pixbuf while another thread replaces and destroys it; the encode
 * then reads a dead GdkPixbuf (SIGSEGV in gdk_pixbuf_get_bits_per_sample,
 * or heap corruption -> SIGABRT).
 *
 * Strategy: DEFER the destroying unref of every pixbuf created through
 * gdk_pixbuf_new_from_data (the cursor path) by GRACE_SEC seconds. Encodes
 * start within milliseconds of creation, so a deferred destruction can never
 * yank the object out from under an in-flight or about-to-start encode.
 * Memory cost is bounded: pending queue holds at most a few seconds' worth
 * of ~100KB cursor images. All other g_object_unref calls pass through
 * untouched, so GLib behavior elsewhere is unchanged.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stddef.h>
#include <time.h>

typedef int gboolean;
typedef unsigned long gsize;

#define GRACE_SEC 3
#define SLOTS 1024

static void *tracked[SLOTS];
static struct { void *obj; time_t due; } pending[SLOTS];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_t reaper_thread;
static int reaper_running;

static void (*real_unref)(void *);

static void *reaper(void *arg) {
    (void)arg;
    struct timespec ts = { 0, 500 * 1000 * 1000 };
    for (;;) {
        nanosleep(&ts, NULL);
        time_t now = time(NULL);
        for (int i = 0; i < SLOTS; i++) {
            void *obj = NULL;
            pthread_mutex_lock(&lock);
            if (pending[i].obj && pending[i].due <= now) {
                obj = pending[i].obj;
                pending[i].obj = NULL;
            }
            pthread_mutex_unlock(&lock);
            if (obj) real_unref(obj);
        }
    }
    return NULL;
}

void *gdk_pixbuf_new_from_data(const void *data, int colorspace, gboolean has_alpha,
        int bits, int w, int h, int rowstride, void *destroy_fn, void *destroy_data) {
    static void *(*real)(const void *, int, gboolean, int, int, int, int, void *, void *);
    if (!real) real = dlsym(RTLD_NEXT, "gdk_pixbuf_new_from_data");
    void *pb = real(data, colorspace, has_alpha, bits, w, h, rowstride, destroy_fn, destroy_data);
    if (pb) {
        pthread_mutex_lock(&lock);
        for (int i = 0; i < SLOTS; i++)
            if (!tracked[i]) { tracked[i] = pb; break; }
        pthread_mutex_unlock(&lock);
    }
    return pb;
}

void g_object_unref(void *obj) {
    if (!real_unref) real_unref = dlsym(RTLD_NEXT, "g_object_unref");
    int defer = 0;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < SLOTS; i++)
        if (tracked[i] == obj) { tracked[i] = NULL; defer = 1; break; }
    if (defer) {
        int placed = 0;
        for (int i = 0; i < SLOTS; i++)
            if (!pending[i].obj) { pending[i].obj = obj; pending[i].due = time(NULL) + GRACE_SEC; placed = 1; break; }
        if (!placed) defer = 0;              /* queue full: fall through to immediate unref */
        else if (!reaper_running) { reaper_running = 1; pthread_create(&reaper_thread, NULL, reaper, NULL); }
    }
    pthread_mutex_unlock(&lock);
    if (!defer) real_unref(obj);
}
CEOF
    if ! cmp -s "$CT_TMP/pixbuf-shim.c" "$SHIM_SRC_DST" 2>/dev/null || [ ! -e "$SHIM_SO" ] || [ ! -e "$SHIM_DROPIN" ]; then
        have gcc || apt_install gcc
        gcc -shared -fPIC -O2 -o "$CT_TMP/pixbuf-shim.so" "$CT_TMP/pixbuf-shim.c" -ldl -pthread \
            || fail "could not compile the pixbuf shim"
        sudo install -d -m 0755 /usr/local/src /usr/local/lib
        sudo install -m 0644 -o root -g root "$CT_TMP/pixbuf-shim.c" "$SHIM_SRC_DST"
        sudo install -m 0644 -o root -g root "$CT_TMP/pixbuf-shim.so" "$SHIM_SO"
        sudo install -d -m 0755 /etc/systemd/system/SRStreamer.service.d
        sudo tee "$SHIM_DROPIN" >/dev/null <<'DEOF'
# Work around use-after-free race in SRFeature's cursor encoder (<=3.8.0.0).
# Source: /usr/local/src/splashtop-pixbuf-shim.c
# Remove this drop-in + `systemctl daemon-reload && systemctl restart SRStreamer`
# once Splashtop ships a fixed streamer.
[Service]
Environment=LD_PRELOAD=/usr/local/lib/splashtop-pixbuf-shim.so
DEOF
        log "restarting Splashtop streamer to load the pixbuf shim (drops any active session for ~30s)"
        sudo systemctl daemon-reload
        sudo systemctl try-restart SRStreamer.service
        sleep 3
        SRPID="$(pgrep -x SRFeature | head -1)"
        if [ -n "$SRPID" ]; then
            sudo grep -q splashtop-pixbuf-shim "/proc/$SRPID/maps" \
                || fail "streamer restarted but the shim is not loaded"
        fi
        CHANGED=1
    fi
fi

# ---- canary: announce streamer updates instead of letting them pass silently --
SRV="$(dpkg-query -W -f '${Version}' splashtop-streamer 2>/dev/null)"
if [ -n "$SRV" ] && dpkg --compare-versions "$SRV" gt "3.8.0.0-1"; then
    next_step "Splashtop streamer is now $SRV (bug was diagnosed on 3.8.0.0): re-test the cursor-encoder crash and retire 41-splashtop-cursorfix if fixed upstream — revert steps are in the module header."
fi

if [ "$CHANGED" = 1 ]; then
    next_step "Splashtop cursor fix changed theme files under a possibly-live session: log out/in (or reboot) so running apps drop cursors built from the old animated files."
    ok "all cursors static (host + snap); launch spinner off; pixbuf race shim active"
else
    ok "already converged (static cursors, no launch spinner, shim in place)"
fi
