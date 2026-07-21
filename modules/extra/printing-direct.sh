# shellcheck shell=bash
# ct-desc: Reliable printing — disable cups-browsed auto-queues; add printers via tools/add-printer.sh

# cups-browsed auto-creates implicitclass:// stub queues, then re-registers
# them under new names over time, orphaning the old ones and silently breaking
# printing. Direct permanent IPP-Everywhere queues remove the indirection.

if pkg_installed cups-browsed; then
    if systemctl is-enabled cups-browsed >/dev/null 2>&1 || systemctl is-active cups-browsed >/dev/null 2>&1; then
        sudo systemctl disable --now cups-browsed || fail "could not disable cups-browsed"
    fi
fi

# Point out leftover auto-queues, if any.
stubs="$(lpstat -v 2>/dev/null | awk '/implicitclass:/ {print $3}' | tr -d ':' | paste -sd' ' -)"
if [ -n "$stubs" ]; then
    next_step "Remove leftover cups-browsed stub queues: sudo lpadmin -x <name>  (found: $stubs)"
fi

next_step "Add each printer as a permanent direct queue: ./tools/add-printer.sh <QueueName> ipp://<printer-host>/ipp/print"
ok "cups-browsed disabled"
