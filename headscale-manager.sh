#!/usr/bin/env bash
# =============================================================================
# Headscale Manager — Interactive script for Oracle Cloud ARM64
# =============================================================================
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/YOURUSERNAME/YOURREPO/main/headscale-manager.sh \
#     | bash
#   or
#   chmod +x headscale-manager.sh && ./headscale-manager.sh
#
# What this script manages:
#   - Install / Update / Uninstall Headscale
#   - Configure Headscale (guided setup)
#   - Start / Stop / Restart / Status
#   - Backup and restore
#   - User and node management
#   - Health checks and diagnostics
#   - Log viewing
#
# Tested on: Oracle Cloud ARM64 (Ampere A1) — Ubuntu 22.04
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================
HEADSCALE_BIN="/usr/local/bin/headscale"
HEADSCALE_CONFIG="/etc/headscale/config.yaml"
HEADSCALE_DATA="/var/lib/headscale"
HEADSCALE_SERVICE="/etc/systemd/system/headscale.service"
HEADSCALE_USER="headscale"
BACKUP_DIR="/opt/headscale-backups"
GITHUB_REPO="juanfont/headscale"

# =============================================================================
# Colours
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
success() { echo -e "${GREEN}[OK]${NC}      $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC}   $*" >&2; }
fatal()   { echo -e "${RED}[FATAL]${NC}   $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }
divider() { echo -e "${CYAN}─────────────────────────────────────────────${NC}"; }

# =============================================================================
# Root check
# =============================================================================
check_root() {
  if [[ $EUID -ne 0 ]]; then
    fatal "This script must be run as root. Try: sudo bash $0"
  fi
}

# =============================================================================
# Helper — get latest Headscale version from GitHub
# =============================================================================
get_latest_version() {
  curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
    | grep '"tag_name"' \
    | cut -d'"' -f4 \
    | tr -d 'v'
}

# =============================================================================
# Helper — get installed version
# =============================================================================
get_installed_version() {
  if [[ -f "$HEADSCALE_BIN" ]]; then
    "$HEADSCALE_BIN" version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown"
  else
    echo "not installed"
  fi
}

# =============================================================================
# Helper — check if headscale is installed
# =============================================================================
is_installed() {
  [[ -f "$HEADSCALE_BIN" ]]
}

# =============================================================================
# Helper — check if service is running
# =============================================================================
is_running() {
  systemctl is-active --quiet headscale 2>/dev/null
}

# =============================================================================
# Helper — press enter to continue
# =============================================================================
pause() {
  echo ""
  read -rp "Press Enter to continue..."
}

# =============================================================================
# INSTALL
# =============================================================================
install_headscale() {
  header "Install Headscale"

  if is_installed; then
    local current
    current=$(get_installed_version)
    warn "Headscale is already installed (version: $current)"
    echo ""
    read -rp "Do you want to reinstall? (y/N): " confirm
    [[ "${confirm,,}" != "y" ]] && return
  fi

  # Get version
  info "Fetching latest Headscale version..."
  local version
  version=$(get_latest_version)

  if [[ -z "$version" ]]; then
    fatal "Could not fetch latest version. Check your internet connection."
  fi

  success "Latest version: $version"
  echo ""
  read -rp "Install version $version? (Y/n): " confirm
  [[ "${confirm,,}" == "n" ]] && return

  # Download
  local download_url="https://github.com/${GITHUB_REPO}/releases/download/v${version}/headscale_${version}_linux_arm64"
  info "Downloading Headscale from GitHub..."
  wget -q --show-progress -O /tmp/headscale "$download_url" \
    || fatal "Download failed. URL: $download_url"

  # Verify size
  local size
  size=$(stat -c%s /tmp/headscale)
  if [[ $size -lt 10000000 ]]; then
    rm -f /tmp/headscale
    fatal "Downloaded file too small (${size} bytes) — likely corrupted."
  fi

  # Backup existing binary if present
  if [[ -f "$HEADSCALE_BIN" ]]; then
    info "Backing up existing binary..."
    cp "$HEADSCALE_BIN" "${HEADSCALE_BIN}.bak"
    success "Backup saved to ${HEADSCALE_BIN}.bak"
  fi

  # Install binary
  chmod +x /tmp/headscale
  mv /tmp/headscale "$HEADSCALE_BIN"
  success "Binary installed at $HEADSCALE_BIN"

  # Create system user
  if ! id "$HEADSCALE_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /bin/false "$HEADSCALE_USER"
    success "System user '$HEADSCALE_USER' created"
  else
    info "System user '$HEADSCALE_USER' already exists"
  fi

  # Create directories
  mkdir -p /etc/headscale "$HEADSCALE_DATA"
  chown "${HEADSCALE_USER}:${HEADSCALE_USER}" "$HEADSCALE_DATA"
  success "Directories created"

  # Config setup
  if [[ ! -f "$HEADSCALE_CONFIG" ]]; then
    configure_headscale
  else
    warn "Config file already exists at $HEADSCALE_CONFIG"
    read -rp "Do you want to reconfigure? (y/N): " confirm
    [[ "${confirm,,}" == "y" ]] && configure_headscale
  fi

  # Install systemd service
  install_service

  # Start service
  systemctl daemon-reload
  systemctl enable --now headscale

  echo ""
  divider
  success "Headscale $version installed and running"
  divider

  # Show status
  show_status

  # Prompt to create user
  echo ""
  read -rp "Create the 'homelab' user namespace now? (Y/n): " confirm
  [[ "${confirm,,}" != "n" ]] && create_user

  pause
}

# =============================================================================
# CONFIGURE — guided setup
# =============================================================================
configure_headscale() {
  header "Configure Headscale"

  echo "This will guide you through creating the config file."
  echo "You will need:"
  echo "  - Your domain name (e.g. yourdomain.com)"
  echo "  - The Headscale subdomain you will use (e.g. hs)"
  echo ""

  # Domain
  read -rp "Enter your domain (e.g. yourdomain.com): " domain
  [[ -z "$domain" ]] && fatal "Domain cannot be empty"

  # Subdomain
  read -rp "Enter Headscale subdomain (default: hs): " subdomain
  subdomain="${subdomain:-hs}"

  # VPN base domain
  read -rp "Enter VPN base domain for MagicDNS (default: vpn.${domain}): " vpn_domain
  vpn_domain="${vpn_domain:-vpn.${domain}}"

  # DNS server
  read -rp "Enter DNS server for clients (default: 1.1.1.1 — change later for Adguard): " dns_server
  dns_server="${dns_server:-1.1.1.1}"

  # Write config
  cat > "$HEADSCALE_CONFIG" << EOF
# =============================================================================
# Headscale Configuration
# Generated by headscale-manager.sh
# =============================================================================

# URL clients use to reach Headscale — must match your Pangolin route
server_url: https://${subdomain}.${domain}

# Listen locally — Pangolin proxies to this
listen_addr: 127.0.0.1:8080
metrics_listen_addr: 127.0.0.1:9090

# Logging
log:
  level: info

# Database
db_type: sqlite3
db_path: ${HEADSCALE_DATA}/db.sqlite

# TLS — handled by Pangolin
tls_cert_path: ""
tls_key_path: ""

# IP range for Tailscale devices (standard CGNAT range)
ip_prefixes:
  - 100.64.0.0/10

# DERP relay — Tailscale public servers as fallback
derp:
  server:
    enabled: false
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  auto_update_enabled: true
  update_frequency: 24h

# DNS pushed to all clients
dns_config:
  override_local_dns: true
  nameservers:
    - ${dns_server}
  magic_dns: true
  base_domain: ${vpn_domain}

# Node settings
disable_check_updates: false
ephemeral_node_inactivity_timeout: 30m

# OIDC — disabled for now
oidc:
  only_start_if_oidc_is_available: false
EOF

  success "Config written to $HEADSCALE_CONFIG"
  echo ""
  info "Remember to:"
  echo "  1. Add DNS record in Cloudflare: ${subdomain}.${domain} → Oracle IP (proxied)"
  echo "  2. Add Pangolin route: ${subdomain}.${domain} → http://127.0.0.1:8080 (auth disabled)"
}

# =============================================================================
# INSTALL SYSTEMD SERVICE
# =============================================================================
install_service() {
  cat > "$HEADSCALE_SERVICE" << 'EOF'
[Unit]
Description=Headscale — self-hosted Tailscale control server
After=network.target

[Service]
Type=simple
User=headscale
Group=headscale
ExecStart=/usr/local/bin/headscale serve
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  success "Systemd service installed"
}

# =============================================================================
# UPDATE
# =============================================================================
update_headscale() {
  header "Update Headscale"

  if ! is_installed; then
    warn "Headscale is not installed. Run Install first."
    pause
    return
  fi

  local current latest
  current=$(get_installed_version)
  info "Fetching latest version..."
  latest=$(get_latest_version)

  echo ""
  echo "  Installed:  $current"
  echo "  Latest:     $latest"
  echo ""

  if [[ "$current" == "$latest" ]]; then
    success "Already on the latest version ($current)"
    pause
    return
  fi

  read -rp "Update from $current to $latest? (Y/n): " confirm
  [[ "${confirm,,}" == "n" ]] && return

  # Take backup before update
  info "Taking backup before update..."
  _do_backup "pre-update-${current}"

  # Download new binary
  local download_url="https://github.com/${GITHUB_REPO}/releases/download/v${latest}/headscale_${latest}_linux_arm64"
  info "Downloading Headscale $latest..."
  wget -q --show-progress -O /tmp/headscale_new "$download_url" \
    || fatal "Download failed"

  # Verify
  chmod +x /tmp/headscale_new
  local new_version
  new_version=$(/tmp/headscale_new version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)

  if [[ -z "$new_version" ]]; then
    rm -f /tmp/headscale_new
    fatal "New binary failed version check. Aborting update."
  fi

  success "New binary verified: $new_version"

  # Stop service, swap binary, restart
  info "Stopping Headscale service..."
  systemctl stop headscale

  # Keep rollback copy
  cp "$HEADSCALE_BIN" "${HEADSCALE_BIN}.bak"
  mv /tmp/headscale_new "$HEADSCALE_BIN"

  info "Starting Headscale service..."
  systemctl start headscale
  sleep 3

  if is_running; then
    success "Update complete — now running version $new_version"
    rm -f "${HEADSCALE_BIN}.bak"
  else
    error "Service failed to start after update — rolling back..."
    systemctl stop headscale
    mv "${HEADSCALE_BIN}.bak" "$HEADSCALE_BIN"
    systemctl start headscale
    error "Rolled back to $current"
  fi

  pause
}

# =============================================================================
# UNINSTALL
# =============================================================================
uninstall_headscale() {
  header "Uninstall Headscale"

  if ! is_installed; then
    warn "Headscale is not installed."
    pause
    return
  fi

  warn "This will remove Headscale completely."
  warn "Your config and data will be backed up first."
  echo ""
  read -rp "Are you sure? Type 'yes' to confirm: " confirm
  [[ "$confirm" != "yes" ]] && { info "Aborted."; pause; return; }

  # Backup first
  info "Taking final backup before uninstall..."
  _do_backup "pre-uninstall"

  # Stop and disable service
  if systemctl is-active --quiet headscale 2>/dev/null; then
    systemctl stop headscale
    success "Service stopped"
  fi

  if systemctl is-enabled --quiet headscale 2>/dev/null; then
    systemctl disable headscale
    success "Service disabled"
  fi

  # Remove files
  rm -f "$HEADSCALE_BIN" "${HEADSCALE_BIN}.bak"
  rm -f "$HEADSCALE_SERVICE"
  systemctl daemon-reload

  echo ""
  read -rp "Also remove config and data? (y/N): " confirm
  if [[ "${confirm,,}" == "y" ]]; then
    rm -rf /etc/headscale "$HEADSCALE_DATA"
    success "Config and data removed"
  else
    info "Config and data kept at /etc/headscale and $HEADSCALE_DATA"
  fi

  # Remove system user
  read -rp "Remove the headscale system user? (y/N): " confirm
  if [[ "${confirm,,}" == "y" ]]; then
    userdel headscale 2>/dev/null && success "User removed" || warn "User not found"
  fi

  success "Headscale uninstalled"
  info "Backup saved at: $BACKUP_DIR"
  pause
}

# =============================================================================
# BACKUP (internal function)
# =============================================================================
_do_backup() {
  local label="${1:-manual}"
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  local backup_path="${BACKUP_DIR}/${timestamp}-${label}"

  mkdir -p "$backup_path"

  # Backup config
  [[ -f "$HEADSCALE_CONFIG" ]] && cp "$HEADSCALE_CONFIG" "$backup_path/"

  # Backup database
  [[ -f "${HEADSCALE_DATA}/db.sqlite" ]] && \
    cp "${HEADSCALE_DATA}/db.sqlite" "$backup_path/"

  # Backup private key if present
  [[ -f "${HEADSCALE_DATA}/private.key" ]] && \
    cp "${HEADSCALE_DATA}/private.key" "$backup_path/"

  # Backup noise private key if present
  [[ -f "${HEADSCALE_DATA}/noise_private.key" ]] && \
    cp "${HEADSCALE_DATA}/noise_private.key" "$backup_path/"

  # Create tarball
  local tarball="${BACKUP_DIR}/${timestamp}-${label}.tar.gz"
  tar -czf "$tarball" -C "$BACKUP_DIR" "${timestamp}-${label}" 2>/dev/null
  rm -rf "$backup_path"

  echo "$tarball"
}

# =============================================================================
# BACKUP (interactive)
# =============================================================================
backup_headscale() {
  header "Backup Headscale"

  mkdir -p "$BACKUP_DIR"

  info "Creating backup..."
  local tarball
  tarball=$(_do_backup "manual")

  if [[ -f "$tarball" ]]; then
    success "Backup created: $tarball"
    echo "  Size: $(du -h "$tarball" | cut -f1)"
  else
    error "Backup failed"
  fi

  # List existing backups
  echo ""
  list_backups

  pause
}

# =============================================================================
# LIST BACKUPS
# =============================================================================
list_backups() {
  header "Existing Backups"

  if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
    info "No backups found at $BACKUP_DIR"
    return
  fi

  echo ""
  printf "  %-50s %s\n" "Backup file" "Size"
  divider
  while IFS= read -r file; do
    printf "  %-50s %s\n" "$(basename "$file")" "$(du -h "$file" | cut -f1)"
  done < <(find "$BACKUP_DIR" -name "*.tar.gz" | sort -r)
  echo ""
}

# =============================================================================
# RESTORE
# =============================================================================
restore_headscale() {
  header "Restore from Backup"

  if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
    warn "No backups found at $BACKUP_DIR"
    pause
    return
  fi

  list_backups

  read -rp "Enter backup filename to restore (just the filename): " backup_file
  local backup_path="${BACKUP_DIR}/${backup_file}"

  if [[ ! -f "$backup_path" ]]; then
    error "File not found: $backup_path"
    pause
    return
  fi

  warn "This will overwrite your current config and database."
  read -rp "Are you sure? Type 'yes' to confirm: " confirm
  [[ "$confirm" != "yes" ]] && { info "Aborted."; pause; return; }

  # Stop service
  systemctl stop headscale 2>/dev/null || true

  # Extract
  local tmp_dir
  tmp_dir=$(mktemp -d)
  tar -xzf "$backup_path" -C "$tmp_dir"

  # Find extracted directory
  local extracted
  extracted=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)

  # Restore files
  [[ -f "${extracted}/config.yaml" ]] && \
    cp "${extracted}/config.yaml" "$HEADSCALE_CONFIG" && \
    success "Config restored"

  [[ -f "${extracted}/db.sqlite" ]] && \
    cp "${extracted}/db.sqlite" "${HEADSCALE_DATA}/db.sqlite" && \
    chown "${HEADSCALE_USER}:${HEADSCALE_USER}" "${HEADSCALE_DATA}/db.sqlite" && \
    success "Database restored"

  [[ -f "${extracted}/private.key" ]] && \
    cp "${extracted}/private.key" "${HEADSCALE_DATA}/private.key" && \
    chown "${HEADSCALE_USER}:${HEADSCALE_USER}" "${HEADSCALE_DATA}/private.key" && \
    success "Private key restored"

  [[ -f "${extracted}/noise_private.key" ]] && \
    cp "${extracted}/noise_private.key" "${HEADSCALE_DATA}/noise_private.key" && \
    chown "${HEADSCALE_USER}:${HEADSCALE_USER}" "${HEADSCALE_DATA}/noise_private.key" && \
    success "Noise private key restored"

  rm -rf "$tmp_dir"

  # Restart
  systemctl start headscale
  sleep 2

  if is_running; then
    success "Headscale restored and running"
  else
    error "Service failed to start after restore — check logs"
  fi

  pause
}

# =============================================================================
# STATUS
# =============================================================================
show_status() {
  header "Headscale Status"

  # Installation
  if is_installed; then
    local version
    version=$(get_installed_version)
    success "Installed:    version $version"
  else
    error   "Installed:    NO"
  fi

  # Service
  if is_running; then
    success "Service:      running"
  else
    error   "Service:      NOT running"
  fi

  # Config
  if [[ -f "$HEADSCALE_CONFIG" ]]; then
    success "Config:       found at $HEADSCALE_CONFIG"
  else
    error   "Config:       NOT found"
  fi

  # Database
  if [[ -f "${HEADSCALE_DATA}/db.sqlite" ]]; then
    local db_size
    db_size=$(du -h "${HEADSCALE_DATA}/db.sqlite" | cut -f1)
    success "Database:     found (${db_size})"
  else
    warn    "Database:     not yet created"
  fi

  # Health endpoint
  echo ""
  info "Checking health endpoint..."
  local health
  health=$(curl -sf http://127.0.0.1:8080/health 2>/dev/null || echo "unreachable")
  if echo "$health" | grep -q "pass"; then
    success "Health:       $health"
  else
    error   "Health:       $health"
  fi

  # Node count
  if is_installed && is_running; then
    echo ""
    info "Connected nodes:"
    headscale nodes list 2>/dev/null || warn "Could not fetch node list"
  fi

  pause
}

# =============================================================================
# SERVICE CONTROL
# =============================================================================
service_control() {
  header "Service Control"
  echo "  1) Start"
  echo "  2) Stop"
  echo "  3) Restart"
  echo "  4) Show service status"
  echo "  5) Back"
  echo ""
  read -rp "Choice: " choice

  case "$choice" in
    1) systemctl start headscale  && success "Started"  || error "Failed to start" ;;
    2) systemctl stop headscale   && success "Stopped"  || error "Failed to stop" ;;
    3) systemctl restart headscale && success "Restarted" || error "Failed to restart" ;;
    4) systemctl status headscale ;;
    5) return ;;
    *) warn "Invalid choice" ;;
  esac

  pause
}

# =============================================================================
# LOGS
# =============================================================================
show_logs() {
  header "Headscale Logs"
  echo "  1) Last 50 lines"
  echo "  2) Last 100 lines"
  echo "  3) Follow live (Ctrl+C to stop)"
  echo "  4) Show errors only"
  echo "  5) Back"
  echo ""
  read -rp "Choice: " choice

  case "$choice" in
    1) journalctl -u headscale -n 50 --no-pager ;;
    2) journalctl -u headscale -n 100 --no-pager ;;
    3) journalctl -u headscale -f ;;
    4) journalctl -u headscale -n 100 --no-pager | grep -i "error\|fatal\|warn" || info "No errors found" ;;
    5) return ;;
    *) warn "Invalid choice" ;;
  esac

  pause
}

# =============================================================================
# USER MANAGEMENT
# =============================================================================
manage_users() {
  header "User Management"
  echo "  1) List users"
  echo "  2) Create user"
  echo "  3) Delete user"
  echo "  4) Back"
  echo ""
  read -rp "Choice: " choice

  case "$choice" in
    1)
      headscale users list
      ;;
    2)
      read -rp "Enter username to create: " username
      [[ -z "$username" ]] && { warn "Username cannot be empty"; pause; return; }
      headscale users create "$username" \
        && success "User '$username' created" \
        || error "Failed to create user"
      ;;
    3)
      headscale users list
      echo ""
      read -rp "Enter username to delete: " username
      [[ -z "$username" ]] && { warn "Username cannot be empty"; pause; return; }
      read -rp "Delete user '$username'? (y/N): " confirm
      [[ "${confirm,,}" != "y" ]] && { info "Aborted"; pause; return; }
      headscale users delete "$username" \
        && success "User '$username' deleted" \
        || error "Failed to delete user"
      ;;
    4) return ;;
    *) warn "Invalid choice" ;;
  esac

  pause
}

# =============================================================================
# NODE MANAGEMENT
# =============================================================================
manage_nodes() {
  header "Node Management"
  echo "  1) List all nodes"
  echo "  2) List online nodes"
  echo "  3) Register a node (enter auth key)"
  echo "  4) Delete a node"
  echo "  5) Rename a node"
  echo "  6) Show node routes"
  echo "  7) Enable a route"
  echo "  8) Back"
  echo ""
  read -rp "Choice: " choice

  case "$choice" in
    1)
      headscale nodes list
      ;;
    2)
      headscale nodes list | grep "true\|online" || headscale nodes list
      ;;
    3)
      read -rp "Enter auth key from client: " auth_key
      read -rp "Enter username to assign to: " username
      [[ -z "$auth_key" || -z "$username" ]] && { warn "Key and username required"; pause; return; }
      headscale nodes register --user "$username" --key "$auth_key" \
        && success "Node registered" \
        || error "Failed to register node"
      ;;
    4)
      headscale nodes list
      echo ""
      read -rp "Enter node ID to delete: " node_id
      read -rp "Delete node $node_id? (y/N): " confirm
      [[ "${confirm,,}" != "y" ]] && { info "Aborted"; pause; return; }
      headscale nodes delete --identifier "$node_id" \
        && success "Node deleted" \
        || error "Failed to delete node"
      ;;
    5)
      headscale nodes list
      echo ""
      read -rp "Enter node ID to rename: " node_id
      read -rp "Enter new name: " new_name
      headscale nodes rename --identifier "$node_id" --new-name "$new_name" \
        && success "Node renamed" \
        || error "Failed to rename node"
      ;;
    6)
      headscale routes list
      ;;
    7)
      headscale routes list
      echo ""
      read -rp "Enter route ID to enable: " route_id
      headscale routes enable --route "$route_id" \
        && success "Route enabled" \
        || error "Failed to enable route"
      ;;
    8) return ;;
    *) warn "Invalid choice" ;;
  esac

  pause
}

# =============================================================================
# PREAUTH KEYS
# =============================================================================
manage_preauth_keys() {
  header "Pre-auth Keys"
  echo "  1) List keys"
  echo "  2) Create a key (single use)"
  echo "  3) Create a key (reusable)"
  echo "  4) Create a key (with expiry)"
  echo "  5) Expire a key"
  echo "  6) Back"
  echo ""
  read -rp "Choice: " choice

  case "$choice" in
    1)
      read -rp "Enter username: " username
      headscale preauthkeys list --user "$username"
      ;;
    2)
      read -rp "Enter username: " username
      headscale preauthkeys create --user "$username" \
        && success "Single-use key created" \
        || error "Failed"
      ;;
    3)
      read -rp "Enter username: " username
      headscale preauthkeys create --user "$username" --reusable \
        && success "Reusable key created" \
        || error "Failed"
      ;;
    4)
      read -rp "Enter username: " username
      read -rp "Enter expiry (e.g. 24h, 7d, 30d): " expiry
      headscale preauthkeys create --user "$username" --expiration "$expiry" \
        && success "Key created with expiry: $expiry" \
        || error "Failed"
      ;;
    5)
      read -rp "Enter username: " username
      headscale preauthkeys list --user "$username"
      echo ""
      read -rp "Enter key to expire: " key
      headscale preauthkeys expire --user "$username" --key "$key" \
        && success "Key expired" \
        || error "Failed"
      ;;
    6) return ;;
    *) warn "Invalid choice" ;;
  esac

  pause
}

# =============================================================================
# CREATE USER (standalone)
# =============================================================================
create_user() {
  read -rp "Enter username to create (default: homelab): " username
  username="${username:-homelab}"
  headscale users create "$username" \
    && success "User '$username' created" \
    || warn "User may already exist"
}

# =============================================================================
# DIAGNOSTICS
# =============================================================================
run_diagnostics() {
  header "Diagnostics"

  echo ""
  info "1. Binary check"
  if [[ -f "$HEADSCALE_BIN" ]]; then
    success "  Binary exists: $HEADSCALE_BIN"
    success "  Version: $(get_installed_version)"
  else
    error "  Binary not found at $HEADSCALE_BIN"
  fi

  echo ""
  info "2. Service check"
  systemctl is-active --quiet headscale \
    && success "  Service is running" \
    || error   "  Service is NOT running"

  systemctl is-enabled --quiet headscale \
    && success "  Service is enabled on boot" \
    || warn    "  Service is NOT enabled on boot"

  echo ""
  info "3. Config check"
  if [[ -f "$HEADSCALE_CONFIG" ]]; then
    success "  Config found"
    # Extract and show server_url
    local server_url
    server_url=$(grep "server_url" "$HEADSCALE_CONFIG" | awk '{print $2}' | tr -d '"')
    info "  server_url: $server_url"
  else
    error "  Config NOT found at $HEADSCALE_CONFIG"
  fi

  echo ""
  info "4. Health endpoint (local)"
  local health
  health=$(curl -sf http://127.0.0.1:8080/health 2>/dev/null || echo "unreachable")
  echo "  Response: $health"

  echo ""
  info "5. Port check"
  ss -tlnp | grep 8080 \
    && success "  Port 8080 is listening" \
    || error   "  Port 8080 is NOT listening"

  echo ""
  info "6. System user check"
  id headscale &>/dev/null \
    && success "  System user 'headscale' exists" \
    || error   "  System user 'headscale' NOT found"

  echo ""
  info "7. Data directory check"
  if [[ -d "$HEADSCALE_DATA" ]]; then
    success "  Data directory exists: $HEADSCALE_DATA"
    local owner
    owner=$(stat -c '%U' "$HEADSCALE_DATA")
    [[ "$owner" == "headscale" ]] \
      && success "  Ownership correct: $owner" \
      || error   "  Wrong ownership: $owner (should be headscale)"
  else
    error "  Data directory NOT found: $HEADSCALE_DATA"
  fi

  echo ""
  info "8. Latest version check"
  local latest current
  current=$(get_installed_version)
  latest=$(get_latest_version 2>/dev/null || echo "unknown")
  if [[ "$current" == "$latest" ]]; then
    success "  Up to date (version $current)"
  else
    warn "  Update available: $current → $latest"
  fi

  echo ""
  info "9. Recent log errors"
  local errors
  errors=$(journalctl -u headscale -n 50 --no-pager 2>/dev/null | grep -i "error\|fatal" | tail -5)
  if [[ -z "$errors" ]]; then
    success "  No recent errors found"
  else
    warn "  Recent errors:"
    echo "$errors" | while read -r line; do
      echo "    $line"
    done
  fi

  pause
}

# =============================================================================
# CLEAN OLD BACKUPS
# =============================================================================
clean_backups() {
  header "Clean Old Backups"

  list_backups

  read -rp "Keep how many most recent backups? (default: 5): " keep
  keep="${keep:-5}"

  local count
  count=$(find "$BACKUP_DIR" -name "*.tar.gz" 2>/dev/null | wc -l)

  if [[ $count -le $keep ]]; then
    info "Only $count backups exist — nothing to clean"
    pause
    return
  fi

  local to_delete=$(( count - keep ))
  info "Deleting $to_delete oldest backups..."

  find "$BACKUP_DIR" -name "*.tar.gz" \
    | sort \
    | head -n "$to_delete" \
    | while read -r file; do
        rm -f "$file"
        info "Deleted: $(basename "$file")"
      done

  success "Done — kept $keep most recent backups"
  pause
}

# =============================================================================
# MAIN MENU
# =============================================================================
main_menu() {
  while true; do
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║         Headscale Manager                 ║"
    echo "  ║         Oracle Cloud ARM64                ║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo -e "${NC}"

    # Quick status line
    local version_str service_str
    version_str=$(get_installed_version 2>/dev/null)
    if is_running; then
      service_str="${GREEN}running${NC}"
    else
      service_str="${RED}stopped${NC}"
    fi
    echo -e "  Version: ${CYAN}${version_str}${NC}   Service: ${service_str}"
    echo ""
    divider

    echo "  Installation"
    echo "    1)  Install Headscale"
    echo "    2)  Update Headscale"
    echo "    3)  Uninstall Headscale"
    echo "    4)  Reconfigure (edit config)"
    echo ""
    echo "  Operations"
    echo "    5)  Service control (start/stop/restart)"
    echo "    6)  Show status"
    echo "    7)  View logs"
    echo "    8)  Run diagnostics"
    echo ""
    echo "  Data"
    echo "    9)  Backup"
    echo "    10) Restore from backup"
    echo "    11) List backups"
    echo "    12) Clean old backups"
    echo ""
    echo "  Headscale management"
    echo "    13) Manage users"
    echo "    14) Manage nodes"
    echo "    15) Manage pre-auth keys"
    echo ""
    echo "    0)  Exit"
    divider
    echo ""
    read -rp "Choice: " choice

    case "$choice" in
      1)  install_headscale ;;
      2)  update_headscale ;;
      3)  uninstall_headscale ;;
      4)  configure_headscale; pause ;;
      5)  service_control ;;
      6)  show_status ;;
      7)  show_logs ;;
      8)  run_diagnostics ;;
      9)  backup_headscale ;;
      10) restore_headscale ;;
      11) list_backups; pause ;;
      12) clean_backups ;;
      13) manage_users ;;
      14) manage_nodes ;;
      15) manage_preauth_keys ;;
      0)  echo ""; info "Goodbye."; echo ""; exit 0 ;;
      *)  warn "Invalid choice — enter a number from the menu" ; sleep 1 ;;
    esac
  done
}

# =============================================================================
# Entry point
# =============================================================================
check_root
main_menu
