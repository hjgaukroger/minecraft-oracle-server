#!/bin/bash
set -euo pipefail

MC_VERSION="26.3"                                  # your Minecraft version
USER_AGENT="my-mc-server-updater/1.0 (<YOUR_EMAIL_OR_URL>)"

cd "$HOME/minecraft"
BUILDS="$(curl -fsS -H "User-Agent: $USER_AGENT" \
  "https://fill.papermc.io/v3/projects/paper/versions/${MC_VERSION}/builds")"

URL="$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads."server:default".url) // empty' <<< "$BUILDS")"
SHA="$(jq -r 'first(.[] | select(.channel == "STABLE") | .downloads."server:default".checksums.sha256) // empty' <<< "$BUILDS")"

if [ -z "$URL" ] || [ -z "$SHA" ]; then
    echo "No stable build (or checksum) found for $MC_VERSION" >&2
    exit 1
fi

curl -fsS -H "User-Agent: $USER_AGENT" -o paper-new.jar "$URL"
echo "$SHA  paper-new.jar" | sha256sum -c -
echo "Downloaded and verified: $URL"
