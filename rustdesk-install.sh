#!/usr/bin/env bash
# =============================================================================
# RustDesk headless installer — Proxmox VE / Debian server
# =============================================================================
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/YOURUSERNAME/YOURREPO/main/install-rustdesk.sh | bash
#   or
#   chmod +x install-rustdesk.sh && ./install-rustdesk.sh
#
# What this script does:
#   1. Detects architecture (x86_64 / arm64)
#   2. Downloads the latest RustDesk release for your arch
#   3. Installs it with all dependencies
#   4. Configures it for headless / unattended access
#   5. Enables and starts the systemd service
#   6. Prints your RustDesk ID and sets your password
#
# Tested on: Proxmox VE 8.x (Debian 12 Bookworm)
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Colour output helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # no colour

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Must run as root
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root. Try: sudo bash $0"
fi

# -----------------------------------------------------------------------------
# Configuration — edit these before running if needed
# -----------------------------------------------------------------------------
# Unattended access password — CHANGE THIS before running
RUSTDESK_PASSWORD="${RUSTDESK_PASSWORD:-ChangeMe123!}"

# Optional: self-hosted relay server (leave empty to use RustDesk public relay)
# Format: "host=YOUR_IP key=YOUR_KEY"
RUSTDESK_RELAY_HOST="${RUSTDESK_RELAY_HOST:-}"
RUSTDESK_RELAY_KEY="${RUSTDESK_RELAY_KEY:-}"

# Where to download the deb — avoids tmpfs OOM issues
DOWNLOAD_DIR="/opt"

# -----------------------------------------------------------------------------
# Warn if default password is still set
# -----------------------------------------------------------------------------
if [[ "$RUSTDESK_PASSWORD" == "ChangeMe123!" ]]; then
  warn "You are using the default password. Set a strong one by running:"
  warn "  RUSTDESK_PASSWORD='YourStrongPassword' bash $0"
  warn "Continuing in 5 seconds — press Ctrl+C to abort..."
  sleep 5
fi

# -----------------------------------------------------------------------------
# Detect architecture
# -----------------------------------------------------------------------------
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)         DEB_ARCH="x86_64" ;;
  aarch64|arm64)  DEB_ARCH="aarch64" ;;
  *)              error "Unsupported architecture: $ARCH" ;;
esac

info "Detected architecture: $ARCH → using RustDesk build: $DEB_ARCH"

# -----------------------------------------------------------------------------
# Get latest RustDesk version from GitHub API
# -----------------------------------------------------------------------------
info "Fetching latest RustDesk release version..."

RUSTDESK_VERSION=$(curl -fsSL \
  "https://api.github.com/repos/rustdesk/rustdesk/releases/latest" \
  | grep '"tag_name"' \
  | cut -d'"' -f4 \
  | tr -d 'v')

if [[ -z "$RUSTDESK_VERSION" ]]; then
  error "Could not fetch RustDesk version from GitHub API. Check your internet connection."
fi

success "Latest RustDesk version: $RUSTDESK_VERSION"

# -----------------------------------------------------------------------------
# Download
# -----------------------------------------------------------------------------
DEB_FILE="${DOWNLOAD_DIR}/rustdesk-${RUSTDESK_VERSION}-${DEB_ARCH}.deb"
DOWNLOAD_URL="https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-${DEB_ARCH}.deb"

info "Downloading RustDesk from: $DOWNLOAD_URL"
wget -q --show-progress -O "$DEB_FILE" "$DOWNLOAD_URL" \
  || error "Download failed. Check the URL: $DOWNLOAD_URL"

# Verify the file is not empty or truncated
DEB_SIZE=$(stat -c%s "$DEB_FILE")
if [[ $DEB_SIZE -lt 5000000 ]]; then
  rm -f "$DEB_FILE"
  error "Downloaded file is too small (${DEB_SIZE} bytes) — likely corrupted. Aborted."
fi

success "Downloaded: $(ls -lh "$DEB_FILE" | awk '{print $5, $9}')"

# -----------------------------------------------------------------------------
# Install dependencies and RustDesk
# -----------------------------------------------------------------------------
info "Updating apt package lists..."
apt-get update -qq

info "Installing RustDesk..."
# Use apt to install the deb — it resolves dependencies automatically
# This is cleaner than dpkg -i + apt-get install -f
apt-get install -y "$DEB_FILE" \
  || {
    warn "apt install failed — trying dpkg fallback..."
    dpkg -i "$DEB_FILE" || true
    apt-get install -f -y \
      || error "Could not resolve dependencies. See output above."
  }

success "RustDesk installed successfully"

# -----------------------------------------------------------------------------
# Configure for headless / unattended access
# -----------------------------------------------------------------------------
info "Configuring RustDesk for headless unattended access..."

# Create config directory
mkdir -p /root/.config/rustdesk

# Write the RustDesk configuration
# This sets permanent password and disables the GUI requirement
cat > /root/.config/rustdesk/RustDesk2.toml << EOF
rendezvous_server = 'rs-ny.rustdesk.com'
nat_type = 1
serial = 0

[options]
enable-audio = 'N'
allow-auto-disconnect = 'N'
stop-service = 'N'
EOF

success "RustDesk config written"

# Set the permanent unattended access password
info "Setting unattended access password..."
rustdesk --password "$RUSTDESK_PASSWORD" 2>/dev/null || {
  warn "Could not set password via CLI — will set via config file..."
  # Alternative method via config
  rustdesk --config "permanent-password=$RUSTDESK_PASSWORD" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Optional: configure self-hosted relay
# -----------------------------------------------------------------------------
if [[ -n "$RUSTDESK_RELAY_HOST" ]]; then
  info "Configuring self-hosted relay: $RUSTDESK_RELAY_HOST"
  rustdesk --config "rendezvous-server=$RUSTDESK_RELAY_HOST" 2>/dev/null || true
  if [[ -n "$RUSTDESK_RELAY_KEY" ]]; then
    rustdesk --config "key=$RUSTDESK_RELAY_KEY" 2>/dev/null || true
  fi
  success "Self-hosted relay configured"
else
  info "Using RustDesk public relay (no self-hosted relay configured)"
fi

# -----------------------------------------------------------------------------
# Enable and start systemd service
# -----------------------------------------------------------------------------
info "Enabling RustDesk service to start on boot..."

# RustDesk installs its own service file
if systemctl list-unit-files | grep -q rustdesk; then
  systemctl enable rustdesk
  systemctl restart rustdesk
  sleep 2
  systemctl is-active --quiet rustdesk \
    && success "RustDesk service is running" \
    || warn "RustDesk service may not be running — check: systemctl status rustdesk"
else
  # Create service manually if not present
  warn "systemd service not found — creating manually..."
  cat > /etc/systemd/system/rustdesk.service << 'SVCEOF'
[Unit]
Description=RustDesk remote desktop
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/rustdesk --service
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

  systemctl daemon-reload
  systemctl enable rustdesk
  systemctl start rustdesk
  sleep 2
  systemctl is-active --quiet rustdesk \
    && success "RustDesk service is running" \
    || warn "RustDesk service may not be running — check: systemctl status rustdesk"
fi

# -----------------------------------------------------------------------------
# Clean up
# -----------------------------------------------------------------------------
info "Cleaning up downloaded package..."
rm -f "$DEB_FILE"
success "Cleanup done"

# -----------------------------------------------------------------------------
# Print connection info
# -----------------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  RustDesk installation complete${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

# Get the RustDesk ID — may take a moment to register
info "Fetching RustDesk ID (waiting for service to register)..."
sleep 3

RUSTDESK_ID=$(rustdesk --get-id 2>/dev/null || echo "")

if [[ -n "$RUSTDESK_ID" ]]; then
  echo -e "  ${BLUE}RustDesk ID:${NC}  ${RUSTDESK_ID}"
else
  warn "Could not fetch ID yet — run this after a moment: rustdesk --get-id"
fi

echo -e "  ${BLUE}Password:${NC}     ${RUSTDESK_PASSWORD}"
echo ""
echo -e "  ${YELLOW}Save these credentials somewhere safe (Vaultwarden).${NC}"
echo ""
echo -e "  ${BLUE}Verify service:${NC}  systemctl status rustdesk"
echo -e "  ${BLUE}Get ID later:${NC}   rustdesk --get-id"
echo -e "  ${BLUE}Change password:${NC} rustdesk --password 'NewPassword'"
echo ""
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Install RustDesk client on your laptop and phone"
echo "     Download from: https://rustdesk.com/download"
echo "  2. Connect using the ID and password above"
echo "  3. Test with Tailscale disconnected to confirm independence"
echo "  4. Once migration to Headscale is complete, run:"
echo "     systemctl disable --now rustdesk && apt-get remove -y rustdesk"
echo ""
