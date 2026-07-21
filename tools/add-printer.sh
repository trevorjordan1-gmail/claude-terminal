#!/usr/bin/env bash
# Create a permanent direct-IPP print queue (IPP Everywhere, no cups-browsed
# indirection). Pair with the printing-direct extra, which disables the flaky
# auto-queue daemon.
#
# Usage:
#   ./add-printer.sh <QueueName> <ipp://printer-host.local/ipp/print>
#
# Find your printer's address: check its network config page, or
# `avahi-browse -rt _ipp._tcp` while it's on.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <QueueName> <ipp://printer-host/ipp/print>" >&2
    exit 2
fi

NAME="$1"
URI="$2"

command -v lpadmin >/dev/null 2>&1 || { echo "CUPS not installed (lpadmin missing)." >&2; exit 1; }

case "$URI" in
    ipp://*|ipps://*) : ;;
    *) echo "URI should start with ipp:// or ipps:// (got: $URI)" >&2; exit 2 ;;
esac

if command -v ipptool >/dev/null 2>&1; then
    echo "[add-printer] probing $URI ..."
    if ! ipptool -tv "$URI" get-printer-attributes.test >/dev/null 2>&1; then
        echo "[add-printer] WARNING: IPP probe failed — printer off or wrong URI? Creating the queue anyway."
    fi
fi

sudo lpadmin -p "$NAME" -E -v "$URI" -m everywhere
echo "[add-printer] queue '$NAME' created and enabled."
echo "[add-printer] test it:  echo test | lp -d '$NAME'"
