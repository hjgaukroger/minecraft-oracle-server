#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin

MC="$HOME/minecraft"
DEST="$HOME/backups"
mkdir -p "$DEST"
STAMP=$(date +%F_%H%M)
ARCHIVE="$DEST/world-$STAMP.tar.gz"

# Check if the 'mc' screen session is active.
# (Capture the output first: piping 'screen -ls' straight into grep can give
# a false "not running" under 'set -o pipefail', which would skip the
# save-off/flush step while the server is live.)
SCREEN_LIST="$(screen -ls || true)"
if grep -q "\.mc[[:space:]]" <<< "$SCREEN_LIST"; then
    trap 'screen -p 0 -S mc -X stuff "save-on$(printf "\r")"' EXIT
    screen -p 0 -S mc -X stuff "save-off$(printf '\r')"
    screen -p 0 -S mc -X stuff "save-all flush$(printf '\r')"
    sleep 15
fi

ITEMS=()
for f in world world_nether world_the_end whitelist.json ops.json server.properties; do
    if [ -e "$MC/$f" ]; then
        ITEMS+=("$f")
    fi
done

if [ ${#ITEMS[@]} -eq 0 ]; then
    echo "$(date): ERROR - no world or config files found in $MC" >&2
    exit 1
fi

if tar -czf "$ARCHIVE" -C "$MC" "${ITEMS[@]}"; then
    find "$DEST" -name 'world-*.tar.gz' -mtime +2 -delete
    echo "$(date): backup done, $(du -h "$ARCHIVE" | cut -f1)"
else
    echo "$(date): ERROR - backup archive failed" >&2
    rm -f "$ARCHIVE"
    exit 1
fi
