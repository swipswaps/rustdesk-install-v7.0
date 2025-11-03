#!/usr/bin/env bash
# rustdesk_key_repair.sh
# Purpose: Fully regenerate proper RustDesk server keypair and restart services
# Compatible with new RustDesk builds that dropped -g flag
# Jose Melendez / 2025-11-02

set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/rustdesk_key_repair.log
}

RUSTDIR="/var/lib/rustdesk-server"
PRIV="$RUSTDIR/id_ed25519"
PUB="$RUSTDIR/id_ed25519.pub"

log "=== Starting RustDesk key repair ==="

# Step 1: Stop services safely
for svc in rustdesk-hbbs rustdesk-hbbr; do
  if systemctl list-units --type=service | grep -q "$svc"; then
    log "Stopping $svc..."
    systemctl stop "$svc" || log "Warning: could not stop $svc (may not be running)"
  else
    log "Service $svc not found, skipping..."
  fi
done

# Step 2: Ensure directory exists and is writable
if [[ ! -d "$RUSTDIR" ]]; then
  log "Creating directory $RUSTDIR..."
  mkdir -p "$RUSTDIR"
fi

# Step 3: Backup old keys if any
if [[ -f "$PRIV" || -f "$PUB" ]]; then
  TS=$(date +%Y%m%d_%H%M%S)
  mkdir -p "$RUSTDIR/backup_$TS"
  mv "$RUSTDIR"/id_ed25519* "$RUSTDIR/backup_$TS/" 2>/dev/null || true
  log "Backed up old keypair to $RUSTDIR/backup_$TS/"
fi

# Step 4: Generate new Ed25519 keypair
log "Generating new Ed25519 keypair..."
ssh-keygen -t ed25519 -N "" -f "$PRIV" <<< y >/dev/null 2>&1

# Step 5: Strip OpenSSH prefixes if needed (RustDesk expects raw base64)
if grep -q "ssh-ed25519" "$PUB"; then
  awk '{print $2}' "$PUB" > "$PUB.tmp" && mv "$PUB.tmp" "$PUB"
  log "Cleaned public key format for RustDesk compatibility."
fi

# Step 6: Fix permissions
chmod 600 "$PRIV"
chmod 644 "$PUB"
chown root:root "$PRIV" "$PUB"
log "Permissions corrected."

# Step 7: Restart services
for svc in rustdesk-hbbs rustdesk-hbbr; do
  log "Starting $svc..."
  systemctl restart "$svc" || log "Error restarting $svc"
  systemctl --no-pager --quiet is-active "$svc" && log "$svc is active." || log "$svc failed to start!"
done

# Step 8: Verify keypair existence and display fingerprint
if [[ -f "$PUB" && -s "$PUB" ]]; then
  FP=$(ssh-keygen -lf "$PUB" | awk '{print $2}')
  log "New RustDesk public key fingerprint: $FP"
  log "Keypair successfully generated in $RUSTDIR/"
else
  log "ERROR: Key generation failed — no public key found."
  exit 1
fi

log "=== RustDesk key repair completed successfully ==="
