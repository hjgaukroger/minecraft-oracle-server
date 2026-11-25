#!/bin/bash
HC_URL="https://hc-ping.com/<YOUR-CHECK-UUID>"
fail() { curl -fsS -m 10 --retry 3 "$HC_URL/fail" > /dev/null || true; exit 1; }

# Problem 1 : the Minecraft service is not running
systemctl is-active --quiet minecraft || fail

# Problem 2 : the disk is 85% full or more
USAGE=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "$USAGE" -lt 85 ] || fail

# All good : send heartbeat
curl -fsS -m 10 --retry 3 "$HC_URL" > /dev/null
