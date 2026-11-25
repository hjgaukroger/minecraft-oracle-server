# Minecraft Server on Oracle Cloud (Paper + Geyser)

A practical, step-by-step runbook for hosting a cross-play Minecraft server on an **Oracle Cloud Always Free Ampere A1 (ARM)** VM running Ubuntu. It supports both **Bedrock Edition** (iPad, mobile, console, Windows via Geyser and Floodgate) and **Java Edition** (via Paper), secured with **Tailscale** and hardened firewalls.

> **Tested Stack:** Ubuntu (ARM64) · Java 25 · Paper 26.3 · Geyser & Floodgate · Spark · Tailscale  
> *(Exact Java, Paper, and Geyser versions, JVM flags, and download URLs change across releases—verify compatibility when updating.)*

---

## Contents

- [Quick Start](#quick-start)
- [Versions Used](#versions-used-last-verified-23-november-2026)
- [Prerequisites](#prerequisites)
- [Architecture Overview](#architecture-overview)
- [1. Oracle Cloud Instance & Network](#1-oracle-cloud-instance--network)
- [2. Software & Directory Layout](#2-software--directory-layout)
- [3. Firewalls (Both Layers Required)](#3-firewalls-both-layers-required)
- [4. Tailscale & Private SSH Access](#4-tailscale--private-ssh-access)
- [5. Connecting Players & Managing Whitelist / Ops](#5-connecting-players--managing-whitelist--ops)
- [6. systemd Service & screen Console](#6-systemd-service--screen-console)
- [7. Automated Backups & Restoring](#7-automated-backups--restoring)
- [8. Updating Paper, Geyser & Floodgate](#8-updating-paper-geyser--floodgate)
- [9. Adding Another Admin Computer](#9-adding-another-admin-computer)
- [10. Troubleshooting & Real-World Lessons](#10-troubleshooting--real-world-lessons)
- [11. Security & Maintenance Checklist](#11-security--maintenance-checklist)
- [12. Optional Improvements](#12-optional-improvements)
- [Notes & Caveats](#notes--caveats)

## Quick Start

The short route from nothing to a working server. Each step points to the section with the detail.

1. Create the Oracle VM and reserve its public IP: [Section 1](#1-oracle-cloud-instance--network). Read the [Oracle gotchas](#oracle-always-free-gotchas) first.
2. Install Java, Paper and the plugins: [Section 2](#2-software--directory-layout).
3. Open the game ports in **both** firewalls: [Section 3](#3-firewalls-both-layers-required).
4. Install Tailscale, test SSH over it, then close port 22: [Section 4](#4-tailscale--private-ssh-access).
5. Whitelist yourself and join: [Section 5](#5-connecting-players--managing-whitelist--ops).
6. Run the server as a `systemd` service: [Section 6](#6-systemd-service--screen-console).
7. Set up backups and test a restore: [Section 7](#7-automated-backups--restoring).
8. Work through the security checklist: [Section 11](#11-security--maintenance-checklist).
9. Optional extras (off-VM backups, alerts, domain name, plugins): [Section 12](#12-optional-improvements).

## Versions Used (last verified 23 November 2026)

| Component | Version |
| :--- | :--- |
| Ubuntu | 22.04 LTS (ARM64) |
| Java | 25 |
| Paper | 26.3 (run `version` in the console to see your exact build) |
| Geyser | 2.12.1, build 1307 (supports Java 26.3 and Bedrock 26.40-26.66) |
| Floodgate | 2.2.5, build 141 |
| Spark, Tailscale | current releases when written |

Minecraft, Paper and Geyser move quickly. If this guide is more than a few weeks old, check each project's current release notes before following the commands exactly.

---

## Prerequisites

Before starting, ensure you have:
- **Oracle Cloud account** with access to an Always Free Ampere A1 (ARM) instance in your chosen region.
- **SSH key pair** on your computer and basic familiarity with the Linux command line.
- **Tailscale account** (free tier works) so SSH can be locked down to your private network rather than exposed to the public internet.
- **Minecraft clients** matching your server version (Bedrock Edition for iPad/mobile/console/Windows; Java Edition for PC).

### Oracle Always Free Gotchas

- **Your home region is fixed at sign-up** and cannot be changed later, so choose one close to your players.
- **"Out of host capacity" errors** when creating an Ampere A1 instance are common. Retry later or try a different availability domain.
- **Allowance:** at the time of writing, Always Free gives 4 OCPUs and 24 GB of memory in total across A1 instances, a 47 GB minimum boot volume, and 200 GB of block storage in total. Stay within it, because Oracle can disable and later delete resources above the free limits.
- **Idle reclamation:** Oracle may reclaim Always Free instances that stay idle (CPU, network and, on A1, memory use all low over a 7-day period). A busy Minecraft server normally counts as active, and upgrading the account to Pay As You Go (still free within the limits) lowers the risk. Check Oracle's current Always Free page for the exact criteria.
- **It is an ARM machine.** Use `aarch64`/ARM64 images and builds. Minecraft and almost all plugins are pure Java and run fine, but any native binary needs an ARM build. For example, Mojang's Bedrock Dedicated Server has no ARM Linux build, which is why this guide uses Geyser instead.
- **Policies change.** Re-check Oracle's Always Free documentation before relying on any specific number here.

---

## Architecture Overview

```text
iPad / Bedrock  ──UDP & TCP 19132──►  Geyser / Floodgate ──┐
                                                           ├──► Paper Server ──► World & Backups
PC / Java       ─────TCP 25565─────────────────────────────┘     (Oracle VM)

Admin Laptop    ──Tailscale (Encrypted)──► SSH (Port 22 closed publicly) ──► Oracle VM
```

### Component Summary

| Layer | Component | Purpose |
| :--- | :--- | :--- |
| **Cloud & OS** | Oracle Cloud Always Free (Ampere A1) | ARM VM (`~11 GB` RAM) with a reserved public IPv4 address (`<YOUR_PUBLIC_IP>`). |
| **Firewalls** | Oracle Security List + `iptables` | Two-layer firewall; ports must be open in **both** places for public game traffic. |
| **Game Server** | Java 25 + Paper (`~/minecraft`) | High-performance Minecraft server supporting plugins and tuned with Aikar's flags (`6 GB` heap). |
| **Cross-Play** | Geyser + Floodgate | Translates Bedrock protocol to Java and allows Bedrock players to join via Microsoft/Xbox accounts without owning Java Edition (prefixed with `.`). |
| **Monitoring** | Spark | In-game performance profiler (`spark tps`). |
| **Operations** | `screen` + `systemd` + `cron` | Auto-starts on boot, restarts on crash, stops cleanly, and runs daily rolling backups. |
| **Admin Access** | Tailscale + SSH Keys | Private mesh VPN (`100.x.y.z`); public port 22 is closed so SSH is invisible to internet scanners. |

### How a Bedrock Player Joins (Step-by-Step)
1. The Bedrock client connects to `<YOUR_PUBLIC_IP>:19132`.
2. Both the Oracle Security List and the VM's `iptables` rules allow the traffic through.
3. Geyser accepts the connection and Floodgate validates the player's Microsoft account.
4. The server checks `whitelist.json`. Unlisted players are rejected.
5. Geyser translates packets between Bedrock and Paper seamlessly.
6. Paper loads the player's inventory and position from `~/minecraft/world`.

---

## 1. Oracle Cloud Instance & Network

1. Create an **Ampere A1 (ARM)** VM running **Ubuntu** (within Oracle Always Free limits, e.g., 2 OCPUs / 12 GB RAM).
2. Attach a **Reserved Public IPv4 Address** to the instance's VNIC so the server address (`<YOUR_PUBLIC_IP>`) never changes across reboots.
3. **Important operational notes:**
   - Never click **Terminate** unless you intend to permanently delete the VM (and if you do, remember to release the reserved IP).
   - Leave the VM running rather than stopping it when unused—starting a stopped Always Free ARM instance can fail due to regional capacity limits (`Out of host capacity`).

---

## 2. Software & Directory Layout

All server files live in `~/minecraft`:

- **Java Runtime:** Java 25 (required for Paper 26.3; Java 21 is insufficient).
- **Server JAR:** `~/minecraft/paper.jar` with `eula=true` set in `~/minecraft/eula.txt`.
- **Plugins (`~/minecraft/plugins/`):**
  - `Geyser-Spigot.jar` — Bedrock-to-Java protocol bridge
  - `floodgate-spigot.jar` — Bedrock authentication without a Java account
  - `spark` — Performance profiler (`spark tps`)

### Installing the Pieces

**Java 25 and tools:**
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y openjdk-25-jre-headless screen jq
java -version
```
If `apt` cannot find `openjdk-25-jre-headless` on your Ubuntu release, install Temurin 25 from the Adoptium apt repository (see adoptium.net) instead. Check that `java -version` reports 25.

**Paper:** create the folder, then download a stable build using the verified script in [Section 8](#8-updating-paper-geyser--floodgate) (or copy the link from papermc.io/downloads):
```bash
mkdir -p ~/minecraft/plugins && cd ~/minecraft
# download paper.jar (Section 8), then:
java -Xms2G -Xmx2G -jar paper.jar --nogui   # first run stops and asks you to accept the EULA
sed -i 's/eula=false/eula=true/' eula.txt
```

**Plugins:** place the Geyser and Floodgate jars in `~/minecraft/plugins/` (download commands in Section 8), then start the server. Set up the `systemd` service in Section 6 so you never need to launch it by hand.

> **Tip:** Always start the server with `~/minecraft` as the working directory; otherwise Paper will generate a blank world in whichever folder you launched it from.

---

## 3. Firewalls (Both Layers Required)

Traffic must pass through **both** Oracle's cloud firewall and Ubuntu's local `iptables` firewall.

### A. Oracle Cloud Security List (Ingress Rules)
In **Networking → VCN → Subnet → Security List**, add three ingress rules with **Source CIDR** `0.0.0.0/0` and **Source Port Range** left blank (`All`):

| Protocol | Destination Port | Purpose |
| :--- | :--- | :--- |
| **TCP** | `25565` | Minecraft Java Edition |
| **UDP** | `19132` | Minecraft Bedrock gameplay traffic |
| **TCP** | `19132` | Geyser initial connection signaling |

*(Double-check that Source Port is blank and Destination Port is populated—putting the port in Source Port will silently block connections.)*

### B. VM Firewall (`iptables`)
Run on the VM:

```bash
sudo iptables -I INPUT -p tcp --dport 19132 -j ACCEPT
sudo iptables -I INPUT -p udp --dport 19132 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 25565 -j ACCEPT
sudo netfilter-persistent save
```

> **Why `-I` and not `-A`:** Oracle's Ubuntu images typically ship with a `REJECT` rule at the end of the `INPUT` chain. `-I` inserts your rule at the top so it is checked first, whereas `-A` would append it after the `REJECT`, where it would never be reached. Check the order with `sudo iptables -L INPUT -n --line-numbers`: your `ACCEPT` lines should sit above any `REJECT` line.

Verify rules and active listeners:

```bash
sudo iptables -L INPUT -n | grep -E "19132|25565"
sudo ss -tlnp | grep 19132
sudo ss -ulnp | grep 19132
```

> **Reboot note:** If players cannot connect after a VM reboot, check `iptables -L INPUT -n` first to ensure rules persisted cleanly.

---

## 4. Tailscale & Private SSH Access

Instead of leaving SSH (port 22) exposed to the internet, use **Tailscale** so only your own signed-in devices can reach SSH over a private `100.x.y.z` address. Players do **not** need Tailscale.

### Step 1: Install Tailscale on the VM
Pick one way to install it:

**Option A: download the installer, read it, then run it** (safer than piping straight into a shell):
```bash
curl -fsSL https://tailscale.com/install.sh -o tailscale-install.sh
less tailscale-install.sh
sh tailscale-install.sh
```

**Option B: use Tailscale's apt repository.** Replace `jammy` with your Ubuntu codename (`lsb_release -cs`), and check tailscale.com/download/linux for the current instructions:
```bash
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list
sudo apt update && sudo apt install -y tailscale
```

Then connect the VM:
```bash
sudo tailscale up
```
Open the printed authentication URL in your browser and approve the VM. Then check its Tailscale IP:
```bash
tailscale ip -4
```

Allow the Tailscale network interface through `iptables`:
```bash
sudo iptables -I INPUT -i tailscale0 -j ACCEPT
sudo netfilter-persistent save
```

### Step 2: Install Tailscale on Your Laptop & Test SSH
1. Install Tailscale from [tailscale.com/download](https://tailscale.com/download) and sign in with the **same account**.
2. Test SSH over Tailscale in a **new terminal window** before making firewall changes:
   ```bash
   ssh -i <path-to-key> ubuntu@100.x.y.z
   ```
3. In the [Tailscale Admin Console](https://login.tailscale.com), select the VM under **Machines** and choose **Disable key expiry** so the VM does not drop off your private network after a few months.

### Step 3: Close Port 22 to the Public Internet
Once Tailscale SSH is confirmed working:
1. Go to **Oracle Console → Networking → VCN → Subnet → Security List**.
2. Delete the ingress rule for **TCP Port 22** (`0.0.0.0/0`).
3. *(Safety net)* If you ever lock yourself out, use **Compute → Instances → Resources → Console connections** in the Oracle Console.

> **Accessing the VM from now on:** with port 22 closed, `ssh ubuntu@<YOUR_PUBLIC_IP>` will time out. That is expected. Make sure Tailscale is running on your laptop and connect to the VM's `100.x.y.z` address instead.

Optional `~/.ssh/config` shortcut on your laptop:
```sshconfig
Host mc
    HostName 100.x.y.z
    User ubuntu
    IdentityFile <path-to-key>
```
Then connect with just `ssh mc`. Run this from your **laptop**: the shortcut exists only in the laptop's SSH config, so typing `ssh mc` on the VM itself gives `Could not resolve hostname mc`.

---

## 5. Connecting Players & Managing Whitelist / Ops

### Bedrock Edition (iPad, Phone, Console, Windows)
1. Open **Minecraft → Play → Servers → Add Server**.
2. Enter:
   - **Address:** `<YOUR_PUBLIC_IP>`
   - **Port:** `19132`
3. Bedrock usernames automatically receive a `.` prefix on the server (e.g., `.<BedrockGamertag>`).

### Java Edition (PC / Mac / Linux)
1. Ensure the client matches the server version (**Java Edition 26.3**).
2. Connect to `<YOUR_PUBLIC_IP>` (default port `25565`) using a matching client version.
3. Keep `online-mode=true` in `~/minecraft/server.properties` so Mojang/Microsoft account authentication is enforced.

### Whitelist, Operators & Game Mode
Open the live server console with `screen -r mc` (detach with `Ctrl+A`, then `D`).

If `fwhitelist add <gamertag>` fails to look up a Bedrock account, temporarily disable the whitelist, have the player join once, and add their prefixed name:

```text
whitelist off
# (Have Bedrock player join once)
whitelist add .<BedrockGamertag>
whitelist add <JavaUsername>
op .<BedrockGamertag>
whitelist on
whitelist list
```

To grant Creative mode without resetting on rejoin, ensure `force-gamemode=false` in `server.properties`, then run:
```text
gamemode creative .<BedrockGamertag>
```

> **Note:** The whitelist and operator (`op`) list are separate—whitelisting lets someone join; `op` grants admin commands.

### Enforce the Whitelist
Set `enforce-whitelist=true` in `server.properties` so that anyone removed from the whitelist is kicked immediately, rather than at their next login:
```bash
sed -i 's/^enforce-whitelist=.*/enforce-whitelist=true/; s/^white-list=.*/white-list=true/' ~/minecraft/server.properties
grep -E "^white-list|^enforce-whitelist" ~/minecraft/server.properties
sudo systemctl restart minecraft
```
Both settings should show `true`. The server only reads `server.properties` at startup, hence the restart.

To review who has logged in recently (useful if an unfamiliar name appears in the console):
```bash
zgrep -h "logged in with entity id" ~/minecraft/logs/*.log.gz ~/minecraft/logs/latest.log | tail -20
```

---

## 6. `systemd` Service & `screen` Console

Running Paper inside a named `screen` session managed by `systemd` ensures clean shutdowns, crash recovery, and easy console access.

### Graceful Stop Script (`~/minecraft/stop.sh`)
```bash
#!/bin/bash
screen -p 0 -S mc -X stuff "stop$(printf '\r')"
while pgrep -u ubuntu -f "paper.jar" > /dev/null; do sleep 1; done
```
Make it executable:
```bash
chmod +x ~/minecraft/stop.sh
```

### Systemd Unit (`/etc/systemd/system/minecraft.service`)
```ini
[Unit]
Description=Minecraft Paper server
After=network-online.target
Wants=network-online.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/minecraft
Type=forking
ExecStart=/usr/bin/screen -dmS mc /usr/bin/java -Xms6G -Xmx6G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC -XX:+AlwaysPreTouch -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 -XX:InitiatingHeapOccupancyPercent=15 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 -jar paper.jar --nogui
ExecStop=/home/ubuntu/minecraft/stop.sh
TimeoutStopSec=120
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### Managing the Service
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now minecraft
sudo systemctl status minecraft --no-pager
sudo systemctl restart minecraft
sudo systemctl stop minecraft
```

- **Attach to console:** `screen -r mc`
- **Detach safely:** Press `Ctrl+A`, release, then press `D` *(never use `Ctrl+C`, which kills the server)*.
- **Check service errors:** `journalctl -u minecraft -n 30 --no-pager` (common pitfalls are typos in memory flags like `-Xms66` or paths like `/hom/ubuntu/...`).

---

## 7. Automated Backups & Restoring

### Backup Script (`~/backup.sh`)
This script pauses auto-saving, flushes chunks to disk, archives the worlds, server configs and plugins (with their configs and data), re-enables saving (even on failure via `trap`), verifies `tar` succeeds, and prunes old archives so about 3 days are kept locally:

```bash
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
for f in world world_nether world_the_end whitelist.json ops.json server.properties plugins; do
    if [ -e "$MC/$f" ]; then
        ITEMS+=("$f")
    fi
done

if [ ${#ITEMS[@]} -eq 0 ]; then
    echo "$(date): ERROR - no world or config files found in $MC" >&2
    exit 1
fi

if tar -czf "$ARCHIVE" --exclude="plugins/Geyser-Spigot/cache" --exclude="*.old" -C "$MC" "${ITEMS[@]}"; then
    find "$DEST" -name 'world-*.tar.gz' -mtime +2 -delete
    echo "$(date): backup done, $(du -h "$ARCHIVE" | cut -f1)"
else
    echo "$(date): ERROR - backup archive failed" >&2
    rm -f "$ARCHIVE"
    exit 1
fi
```

Make executable and schedule daily at `04:00` server time (`crontab -e`):
```bash
chmod +x ~/backup.sh
```
```cron
0 4 * * * /home/ubuntu/backup.sh >> /home/ubuntu/backup.log 2>&1
```

> **Why the log lives outside `~/backups`:** anything in that folder gets copied off-VM by the rclone job in [Section 12](#12-optional-improvements). Keeping logs in your home folder keeps the backups folder to archives only.

> **Sizing retention:** `-mtime +2` keeps about 3 daily archives. Check archive sizes with `ls -lh ~/backups` and free space with `df -h /`. A world that has been pre-generated with Chunky (or explored heavily) can produce archives of several GB each, so raise retention only if the disk has room for it.

**Test it once with the server running** before relying on it: run `~/backup.sh`, and in the server console (`screen -r mc`) you should see `Automatic saving is now disabled`, then `Automatic saving is now enabled`. Check the new archive exists with `ls -lh ~/backups` and that it lists correctly with `tar -tzf ~/backups/world-*.tar.gz | head`.

### Off-VM Backups
Local backups do not protect against losing the VM itself. Periodically copy an archive to your laptop over Tailscale:
```bash
scp -i <path-to-key> ubuntu@100.x.y.z:~/backups/world-*.tar.gz .
```

### Restoring from a Backup
1. Stop the server cleanly:
   ```bash
   sudo systemctl stop minecraft
   ```
2. **Move the current world folders aside** (do not extract on top of them, or stale files from the old world will be mixed into the restored one):
   ```bash
   mkdir -p ~/old-worlds
   for d in world world_nether world_the_end; do
       [ -e ~/minecraft/$d ] && mv ~/minecraft/$d ~/old-worlds/$d-$(date +%F_%H%M)
   done
   ```
3. Check what the archive contains, then extract it. The first command restores **only the worlds**; the second restores **everything** in the archive, which also overwrites `whitelist.json`, `ops.json`, `server.properties` and the `plugins` folder with the backed-up copies (what you want after losing the VM):
   ```bash
   tar -tzf ~/backups/world-YYYY-MM-DD_HHMM.tar.gz | head
   tar -xzf ~/backups/world-YYYY-MM-DD_HHMM.tar.gz -C ~/minecraft world world_nether world_the_end
   # or, to restore everything in the archive:
   tar -xzf ~/backups/world-YYYY-MM-DD_HHMM.tar.gz -C ~/minecraft
   ```
   *(If an archive has no `world_nether` or `world_the_end` folder, drop those names from the first command.)*
4. Start the server again and check the console and `spark tps`:
   ```bash
   sudo systemctl start minecraft
   ```
5. Delete `~/old-worlds` once you are happy with the restored world.

---

## 8. Updating Paper, Geyser & Floodgate

Always run a backup and stop the server cleanly before updating:
```bash
~/backup.sh
sudo systemctl stop minecraft
```
*(Wait up to 120 seconds for Java to exit; verify with `pgrep -a java`. Avoid `kill -9`, which can corrupt world chunks.)*

### Update Paper (stable build, checksum verified)
Paper's downloads service asks for a descriptive `User-Agent` that includes a contact URL or email (generic ones such as `curl` or `wget` are not allowed), and it recommends stable builds only. This script downloads the latest **stable** build for your Minecraft version into `~/minecraft/paper-new.jar` and checks its SHA-256 checksum. It does not touch your running server.

```bash
cat > ~/update-paper.sh << 'EOF'
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
EOF
chmod +x ~/update-paper.sh
```
Run it, then swap the jar in:
```bash
~/update-paper.sh
~/backup.sh
sudo systemctl stop minecraft
cd ~/minecraft
mv paper.jar paper.jar.old
mv paper-new.jar paper.jar
sudo systemctl start minecraft
```
*(Roll back with `mv paper.jar.old paper.jar` if needed; delete `.old` files once verified. If the script reports no stable build, the newest build is experimental, so stay on what you have.)*

### Update Geyser & Floodgate (pinned builds)
The `latest` URLs are quick but unpredictable: a new build can change behaviour the moment you download it. Pinning a build number and checking its checksum is safer. Find build numbers with `geyser version` in the console or on geysermc.org/download.

```bash
cd ~/minecraft/plugins
GEYSER_BUILD=<build-number>        # e.g. 1307
mv Geyser-Spigot.jar Geyser-Spigot.jar.old
wget -O Geyser-Spigot.jar "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/${GEYSER_BUILD}/downloads/spigot"

# Compare these two values: they should be identical
curl -fsS "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/${GEYSER_BUILD}" | jq -r '.downloads.spigot.sha256'
sha256sum Geyser-Spigot.jar
```
Repeat for Floodgate (`projects/floodgate`, file `floodgate-spigot.jar`, its own build number). If `jq` prints `null`, run the `curl` without the `jq` part to see the field names in the response.

**Quick (unpinned) method**, if you accept the risk:
```bash
cd ~/minecraft/plugins
mv Geyser-Spigot.jar Geyser-Spigot.jar.old
wget -O Geyser-Spigot.jar https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest/downloads/spigot
mv floodgate-spigot.jar floodgate-spigot.jar.old
wget -O floodgate-spigot.jar https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest/downloads/spigot
```

Start the server and check:
```bash
sudo systemctl start minecraft
```
Then run `geyser version` (it should say no updates, and list the supported Bedrock range) and `spark tps` in the console. If anything breaks, stop the service, restore the `.old` jars and start it again. Delete the `.old` files once everything works.

---

## 9. Adding Another Admin Computer

Each admin machine needs **(A)** Tailscale access to your network and **(B)** its own unique SSH key pair. **Never copy private keys between computers or commit them to Git.**

1. **Install Tailscale** on the new computer, sign into the same account, and test `tailscale ping 100.x.y.z`.
2. **Generate an SSH key** on the new computer:
   ```bash
   ssh-keygen -t ed25519 -C "second-laptop"
   cat ~/.ssh/id_ed25519.pub
   ```
   *(On Windows PowerShell: `type $env:USERPROFILE\.ssh\id_ed25519.pub`)*
3. **Authorize the public key** from an already-connected machine (use `>>` to append; **never** use `>`):
   ```bash
   echo "ssh-ed25519 AAAA...your-public-key... second-laptop" >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```
   Verify with `cat ~/.ssh/authorized_keys` that the key sits on a **single unbroken line**.
4. **Test login** from the new computer before closing your existing session:
   ```bash
   ssh -i ~/.ssh/id_ed25519 ubuntu@100.x.y.z
   ```
5. **To revoke access later:** Remove the key's line from `~/.ssh/authorized_keys` on the VM and remove the device in the Tailscale Admin Console.

---

## 10. Troubleshooting & Real-World Lessons

- **Bedrock error `Terracotta / InitialConnection-149`:** Usually indicates **TCP `19132`** is blocked even when UDP `19132` is open. Geyser requires both protocols on port `19132`.
- **`Command 'stop' not found`:** You typed `stop` in the Linux shell instead of the Minecraft console (`screen -r mc`).
- **Duplicate Java processes:** Before starting via `systemd`, check `pgrep -a java` and `screen -ls` to make sure a manual server instance isn't already holding the port or world lock.
- **Harmless startup log messages:**
  - `Send failed, errno=101` (IPv6 STUN check on IPv4-only networks)
  - `sun.misc.Unsafe` deprecation warnings from Java/Netty
  - `en_ is not a supported Floodgate language`
- **Reduce noisy Geyser logs:** Set `debug-mode: false` in `~/minecraft/plugins/Geyser-Spigot/config.yml` and run `geyser reload`.

---

## 11. Security & Maintenance Checklist

Work through these and verify each one on your own server. Don't assume a default is already in place.

- [ ] **SSH closed publicly:** no ingress rule for TCP port 22 in the Oracle Security List; SSH only works over Tailscale (`100.x.y.z`). Test: `ssh` to the public IP should time out.
- [ ] **Key-only SSH:** password logins are off. Verify: `sudo sshd -T | grep -E "passwordauthentication|permitrootlogin"` should show `passwordauthentication no`, and `permitrootlogin` as `no` or `prohibit-password`. Use a unique key per admin device.
- [ ] **2FA enabled** on both your Oracle Cloud and Tailscale accounts.
- [ ] **Budget alert:** in **Billing & Cost Management → Budgets**, create a budget on the root compartment (for example 1 per month in your account's currency) with an **Actual Spend** alert rule at an absolute amount of `0.01`. It only emails you (it does not cap spending), but you hear about any charge long before the bill.
- [ ] **Backup bucket is private:** archives include `plugins/floodgate/key.pem`, plugin configs and player names, so the Object Storage bucket must be **Private** (or use rclone's `crypt` remote).
- [ ] **Automatic OS security updates:** `sudo dpkg-reconfigure -plow unattended-upgrades`, then verify: `apt-config dump | grep Unattended-Upgrade` should show `"1"`.
- [ ] **Server access controls:** verify with `grep -E "^white-list|^enforce-whitelist|^online-mode" ~/minecraft/server.properties`. All three should be `true`. Note that the setting is named `white-list` (with a hyphen) in `server.properties`, and `whitelist on` in the console switches it on.
- [ ] **Periodic maintenance:**
  - Run `sudo apt update && sudo apt upgrade -y` (reboot if `/var/run/reboot-required` exists).
  - Don't run `do-release-upgrade` casually when the login message offers a new Ubuntu release: it can change Java and other packages under the server. Plan it as a separate job with a fresh, downloaded backup.
  - Audit open listening sockets with `sudo ss -tlnp` and `sudo ss -ulnp` (only `19132`, `25565`, and Tailscale interfaces should appear publicly).
  - Copy a world backup archive off the VM periodically.
  - Glance at the Healthchecks.io dashboard (if set up in [Section 12](#uptime--disk-alerts)): the check should be green with a recent ping.

### Optional Next Steps
See [Section 12](#12-optional-improvements) for off-VM backups, uptime and disk alerts, a domain name, and plugins.

---

## 12. Optional Improvements

### Automatic Off-VM Backups
Backups on the same VM do not protect you if the VM itself is lost. `rclone` can push each night's archive to storage elsewhere.

- **Where to:** Oracle's own Object Storage (Always Free currently includes about 20 GiB of combined Object and Archive storage; check Oracle's page, and note archives grow with your world), or any cloud drive rclone supports.
- **Install rclone** from rclone.org/downloads rather than `apt`, because the version in Ubuntu 22.04's repositories is old and may lack your provider.
- **Set up a remote:** run `rclone config`, create a remote (for example `offsite`), and follow rclone's guide for your provider. Test it with `rclone lsd offsite:`.
- **Schedule it** with `crontab -e`, after the 04:00 backup has finished:
```cron
30 4 * * * /usr/local/bin/rclone copy /home/ubuntu/backups offsite:minecraft-backups --include "world-*.tar.gz" --max-age 24h --log-file /home/ubuntu/rclone.log
45 4 * * * /usr/local/bin/rclone delete offsite:minecraft-backups --min-age 3d --log-file /home/ubuntu/rclone.log
```
The first line copies only the world archives from the last day; the second removes copies older than 3 days.

- **Use the full path to rclone.** cron runs with a minimal `PATH` that may not include `/usr/local/bin`, where the official installer puts it. Check yours with `which rclone`.
- **Keep the log outside `~/backups`**, otherwise rclone writes its log into the folder it is copying. `--include` is a second guard so only archives are uploaded.
- **Size retention to the free allowance.** Roughly: archive size × days kept must stay well under about 20 GiB. At 2.8 GB per archive, 3 days is about 8.5 GB, while 14 days would be about 39 GB and uploads would start failing. If your archives are small, you can raise `--min-age`.
- **Check the total** now and then:
```bash
rclone size offsite:minecraft-backups
rclone ls offsite:minecraft-backups
```
If a stray log file was uploaded earlier, remove it with `rclone delete offsite:minecraft-backups --include "*.log"`.

Archives contain your world, your whitelist/ops files (player names and IDs) and plugin data including Floodgate's `key.pem`, so encrypt them (rclone's `crypt` remote) if the storage is not private. Restore from an off-VM copy once to prove it works.

### Uptime & Disk Alerts
Nothing warns you if the disk fills up or the server dies. A free "dead man's switch" service such as Healthchecks.io emails you when your VM **stops pinging**, and when the script below reports a problem. Check the service's current free limits.

1. **Create the check.** Sign up at healthchecks.io, click **Add Check**, set **Period** to 5 minutes and **Grace Time** to about 10 minutes, and copy its ping URL (`https://hc-ping.com/<uuid>`). Email alerts to your sign-up address are on by default; add others (Discord, Telegram and so on) under **Integrations**.
2. **Create `~/healthcheck.sh`** on the VM. Paste the block rather than retyping it, then replace `<YOUR-CHECK-UUID>`:
```bash
cat > ~/healthcheck.sh << 'EOF'
#!/bin/bash
HC_URL="https://hc-ping.com/<YOUR-CHECK-UUID>"
fail() { curl -fsS -m 10 --retry 3 "$HC_URL/fail" > /dev/null || true; exit 1; }

# Problem 1: the Minecraft service is not running
systemctl is-active --quiet minecraft || fail

# Problem 2: the disk is 85% full or more
USAGE=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "$USAGE" -lt 85 ] || fail

# All good: send the heartbeat
curl -fsS -m 10 --retry 3 "$HC_URL" > /dev/null
EOF
chmod +x ~/healthcheck.sh
grep HC_URL= ~/healthcheck.sh     # check the URL went in correctly
```
3. **Test it by hand** before scheduling it:
```bash
~/healthcheck.sh; echo "exit code: $?"
```
`exit code: 0` with no other output means all is well, and the check turns green on the dashboard within seconds. `exit code: 1` means the script found a problem (and sent a failure ping): check `systemctl is-active minecraft` and `df -h /`. If the disk is already at 85% or more (easy after running Chunky), free space first or you will be alerted straight away.
4. **Run it every 5 minutes** (`crontab -e`), then confirm with `crontab -l`:
```cron
*/5 * * * * /home/ubuntu/healthcheck.sh
```
5. **Test the alert** once, without touching the server, by sending a manual failure. You should get an email, and the next scheduled run turns the check green again:
```bash
curl -fsS "https://hc-ping.com/<YOUR-CHECK-UUID>/fail"
```

If the VM, its network or cron stops, the pings stop and you get an alert. If the service is down or the disk is nearly full, the script reports a failure straight away.

- **Keep the ping URL private.** Anyone with it can send fake pings to your check (though not reach your server). Blur it in screenshots, or generate a new one in the check's settings and update line 2 of the script.

### Domain Name
Buy a domain and create an **A record** (for example `play.example.com`) pointing at your reserved public IP. Players then enter the name instead of the IP. Both ports are the defaults (Java `25565`, and Bedrock's port box is pre-filled with `19132`), so no SRV record is needed. Set the record to **DNS only**: proxying services such as Cloudflare's orange-cloud mode do not carry game traffic. A domain makes the IP easy to look up, so keep the whitelist on.

### Permissions & Quality-of-Life Plugins
- **LuckPerms:** permission groups, so trusted players get limited commands without full `op`.
- **GriefPrevention:** land claims to stop griefing.
- **EssentialsX:** homes, warps and teleport requests.
- **Chunky:** pre-generates terrain so exploring does not cause lag spikes. **Warning:** it can grow the world (and every backup archive) from megabytes to several GB overnight, and uses a lot of CPU while running. Check progress with `chunky progress`, pause with `chunky pause`, and review backup retention in [Section 7](#7-automated-backups--restoring) and [Section 12](#automatic-off-vm-backups) afterwards.

Before installing any plugin, check that it supports your Paper version (new Minecraft versions often outpace plugins), take a backup, drop the jar into `~/minecraft/plugins/`, restart with `sudo systemctl restart minecraft`, and read the console for errors. Some plugin menus and commands may not translate cleanly for Bedrock players through Geyser.

---

## Notes & Caveats

- **Costs and limits:** Always Free allowances and policies can change, so check Oracle's current Always Free page. Staying inside the free limits keeps this at no cost, but you are responsible for what you provision.
- **Licensing:** if you run a public or monetised server, read Mojang's Minecraft EULA and commercial usage guidelines. This guide is unofficial and not affiliated with Mojang, Microsoft, Oracle, PaperMC, GeyserMC or Tailscale.
- Replace all placeholder values (`<YOUR_PUBLIC_IP>`, `100.x.y.z`, `<BedrockGamertag>`, `<JavaUsername>`, and key paths) with your own before applying commands.
- Test the backup and restore steps once on your own setup before you depend on them.
- Always test configuration changes on your own setup and keep off-VM backups; these scripts and instructions are provided as-is without warranty.