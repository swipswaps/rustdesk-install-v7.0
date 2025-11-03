#!/usr/bin/env bash
# ==========================================================
# rustdesk_install_v41.sh — Fully Upgraded Installer
# ==========================================================
# Features:
# - Detect architecture
# - Install dependencies
# - Install RustDesk server binaries (hbbs + hbbr)
# - Generate server keys if missing
# - Configure systemd units for hbbs & hbbr
# - Configure firewall 21115‑21119 TCP/UDP
# - Optional TLS via stunnel
# - NAT detection & external reachability check
# - Generate client info, clipboard copy, and QR code
# - Improved NAT warnings and optional external tunnel instructions
# ==========================================================

set -euo pipefail
IFS=$'\n\t'
LOGTAG="[RustDesk‑Server‑Installer]"
WORKDIR="/opt/rustdesk-server"
BIN_DIR="/usr/local/bin"
DATA_DIR="/var/lib/rustdesk-server"
SYSTEMD_DIR="/etc/systemd/system"
LOGFILE="$WORKDIR/install.log"

mkdir -p "$WORKDIR" "$DATA_DIR"

function log()  { echo -e "[$(date '+%F %T')] ${LOGTAG} $*" | tee -a "$LOGFILE"; }
function warn() { echo -e "[$(date '+%F %T')] [WARN] $*" | tee -a "$LOGFILE" >&2; }
function prompt_yes_no() { local prompt="$1"; while true; do read -rp "$prompt [y/n]: " yn; case $yn in [Yy]*) return 0 ;; [Nn]*) return 1 ;; *) echo "Please answer y or n." ;; esac; done }

# --------------------------
# Detect architecture
# --------------------------
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCHTAG="amd64" ;;
    aarch64) ARCHTAG="arm64" ;;
    armv7l) ARCHTAG="armhf" ;;
    i386|i686) ARCHTAG="i386" ;;
    *) log "Unsupported architecture: $ARCH"; exit 1 ;;
esac
log "Detected architecture: $ARCHTAG"

# --------------------------
# Dependencies
# --------------------------
log "Installing dependencies..."
sudo dnf -y install curl wget tar unzip firewalld systemd openssh stunnel qrencode xclip jq nc >/dev/null || warn "Some dependencies may already exist"

# --------------------------
# Public IP/domain
# --------------------------
LOCAL_IP=$(hostname -I | awk '{print $1}')
DETECTED_IP=$(curl -s ifconfig.me || echo "$LOCAL_IP")
read -rp "Enter your public IP or domain (must resolve to this server) [${DETECTED_IP}]: " PUBLIC_ADDR
PUBLIC_ADDR=${PUBLIC_ADDR:-$DETECTED_IP}
log "Using public address: $PUBLIC_ADDR"

# --------------------------
# NAT Detection
# --------------------------
if [[ "$LOCAL_IP" != "$PUBLIC_ADDR" ]]; then
    warn "Detected NAT/Firewall: Local IP $LOCAL_IP != Public IP $PUBLIC_ADDR"
    warn "External clients may need port forwarding for TCP/UDP 21115-21119"
    warn "You can optionally use an external tunnel service (ngrok/frp) if port forwarding is unavailable."
else
    log "No NAT detected: local IP matches public IP"
fi

# --------------------------
# Fetch latest RustDesk release
# --------------------------
API_URL="https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest"
TMP_JSON=$(mktemp)
curl -sL "$API_URL" -o "$TMP_JSON"
TAG=$(jq -r '.tag_name' "$TMP_JSON")
[[ -z "$TAG" || "$TAG" == "null" ]] && { log "Error: unable to parse release tag"; exit 1; }
log "Latest release: $TAG"

# --------------------------
# Download server zip if not already present
# --------------------------
ZIP_URL=$(jq -r --arg ARCHTAG "$ARCHTAG" '.assets[] | select(.name|test("linux.*zip$")) | select(.name|test($ARCHTAG)) | .browser_download_url' "$TMP_JSON")
[[ -z "$ZIP_URL" || "$ZIP_URL" == "null" ]] && { log "No compatible zip found"; exit 1; }

if [[ -f "$WORKDIR/rustdesk-server.zip" ]]; then
    log "Using existing server zip"
else
    log "Downloading server zip: $ZIP_URL"
    curl -L -o "$WORKDIR/rustdesk-server.zip" "$ZIP_URL"
fi

sudo unzip -o -q "$WORKDIR/rustdesk-server.zip" -d "$WORKDIR"

# --------------------------
# Install server binaries
# --------------------------
for BIN in hbbs hbbr rustdesk-utils; do
    BIN_SRC=$(find "$WORKDIR" -type f -name "$BIN" | head -n1)
    [[ -z "$BIN_SRC" ]] && { log "$BIN binary not found"; exit 1; }
    sudo mv "$BIN_SRC" "$BIN_DIR/$BIN"
    sudo chmod +x "$BIN_DIR/$BIN"
    log "Installed binary: $BIN_DIR/$BIN"
done

# --------------------------
# Server keys
# --------------------------
PUBKEY_FILE="$DATA_DIR/id_ed25519.pub"
SECRETKEY_FILE="$DATA_DIR/id_ed25519"

if [[ ! -f "$PUBKEY_FILE" || ! -f "$SECRETKEY_FILE" ]]; then
    log "Generating server key pair..."
    sudo $BIN_DIR/rustdesk-utils genkeypair > "$DATA_DIR/id_ed25519.tmp"
    sudo head -n1 "$DATA_DIR/id_ed25519.tmp" > "$PUBKEY_FILE"
    sudo tail -n1 "$DATA_DIR/id_ed25519.tmp" > "$SECRETKEY_FILE"
    sudo rm -f "$DATA_DIR/id_ed25519.tmp"
    sudo chmod 600 "$SECRETKEY_FILE" "$PUBKEY_FILE"
    log "Server keys generated successfully"
else
    log "Server keys already exist, reusing"
fi

# --------------------------
# Optional TLS via stunnel
# --------------------------
USE_TLS=false
if prompt_yes_no "Do you want to enable TLS (stunnel) for hbbs?"; then
    USE_TLS=true
    TLS_DIR="$WORKDIR/tls"
    mkdir -p "$TLS_DIR"
    TLS_CERT="$TLS_DIR/rustdesk.crt"
    TLS_KEY="$TLS_DIR/rustdesk.key"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$TLS_KEY" -out "$TLS_CERT" -subj "/CN=rustdesk.local"
    log "TLS certificate generated at $TLS_CERT"
fi

# --------------------------
# Systemd units for hbbs & hbbr
# --------------------------
log "Creating systemd units..."
sudo tee "$SYSTEMD_DIR/hbbs.service" >/dev/null <<EOF
[Unit]
Description=RustDesk hbbs server
After=network.target

[Service]
ExecStart=$BIN_DIR/hbbs -k $SECRETKEY_FILE
WorkingDirectory=$DATA_DIR
Restart=always
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

sudo tee "$SYSTEMD_DIR/hbbr.service" >/dev/null <<EOF
[Unit]
Description=RustDesk hbbr relay server
After=network.target

[Service]
ExecStart=$BIN_DIR/hbbr
Restart=always
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now hbbs hbbr
log "hbbs & hbbr services started"

# --------------------------
# Firewall
# --------------------------
log "Configuring firewall ports 21115‑21119 TCP/UDP"
sudo systemctl enable --now firewalld
for p in {21115..21119}; do
    sudo firewall-cmd --permanent --add-port=${p}/tcp >/dev/null 2>&1 || warn "Failed TCP $p"
    sudo firewall-cmd --permanent --add-port=${p}/udp >/dev/null 2>&1 || warn "Failed UDP $p"
done
sudo firewall-cmd --reload

# --------------------------
# Client info + QR code
# --------------------------
CLIENT_INFO_FILE="$WORKDIR/client_info.txt"
PUBKEY=$(<"$PUBKEY_FILE")
sudo tee "$CLIENT_INFO_FILE" >/dev/null <<EOF
------------------------------------------
✅ RustDesk Client Configuration
------------------------------------------
Relay: ${PUBLIC_ADDR}:21117
ID:    ${PUBLIC_ADDR}
Key:   ${PUBKEY}

Saved copy: ${CLIENT_INFO_FILE}
------------------------------------------
EOF
log "Client info written to $CLIENT_INFO_FILE"

# Clipboard fix: run xclip as real user
if command -v xclip >/dev/null 2>&1 && [[ -n "${DISPLAY-}" ]]; then
    REALUSER=$(logname 2>/dev/null || echo "$SUDO_USER")
    if [[ -n "$REALUSER" ]]; then
        sudo -u "$REALUSER" XAUTHORITY="/home/$REALUSER/.Xauthority" DISPLAY="$DISPLAY" xclip -sel clip < "$CLIENT_INFO_FILE" && log "Copied client info to clipboard"
    else
        warn "No valid GUI user detected, skipping clipboard copy"
    fi
else
    warn "xclip or DISPLAY not available, skipping clipboard copy"
fi

# QR code
if command -v qrencode >/dev/null 2>&1; then
    QR_STRING="relay=${PUBLIC_ADDR}&id=${PUBLIC_ADDR}&key=${PUBKEY}"
    qrencode -t UTF8 "${QR_STRING}" || true
    sudo qrencode -o "$WORKDIR/rustdesk_qr.png" "${QR_STRING}" || true
    log "QR code generated at $WORKDIR/rustdesk_qr.png"
fi

# --------------------------
# External port check
# --------------------------
log "Checking TCP ports externally (may fail if behind NAT)..."
for p in {21115..21119}; do
    nc -z -v -w3 "$PUBLIC_ADDR" $p >/dev/null 2>&1 && status="OPEN" || status="CLOSED"
    echo "Port $p TCP: $status"
done

# --------------------------
# Summary
# --------------------------
echo -e "\n=================================================="
echo -e "✅ RustDesk Server installation complete!"
systemctl --no-pager status hbbs | grep Active:
echo -e "\nClient info: $CLIENT_INFO_FILE"
[[ -f "$WORKDIR/rustdesk_qr.png" ]] && echo "QR code: $WORKDIR/rustdesk_qr.png"
echo -e "\nNext steps:"
echo -e "1. Copy client info to RustDesk client or use QR."
echo -e "2. Ensure firewall/router allows ports 21115-21119 TCP/UDP."
echo -e "3. If behind NAT, configure port forwarding or use external tunnel (ngrok/frp)."
echo -e "4. Check server logs: sudo journalctl -u hbbs -f"
echo -e "5. Restart services if needed: sudo systemctl restart hbbs hbbr"
echo -e "==================================================\n"

exit 0
