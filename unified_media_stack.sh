#!/bin/bash
set -euo pipefail

# ==============================================================================
# UNIFIED MEDIA STACK INSTALLER (SAILARR ARCHITECTURE + CLOUDFLARE)
# Installs Docker, configures advanced media services (Zurg/Rclone/Decypharr),
# and deploys secure ingress using Cloudflare Tunnel.
# ==============================================================================

# --- Color and Logging Helpers ---
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

log_info() { echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $1"; }
log_success() { echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $1"; }
log_warning() { echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} $1"; }
log_error() { echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1" >&2; }
log_section() { echo -e "\n${COLOR_BLUE}--- $1 ---${COLOR_RESET}"; }

# --- UID/GID and User Setup Functions (Simplified from setup-users.sh) ---

find_available_id() {
    local type=$1
    local base_id=$2
    local current_id=$base_id
    local command_name

    if [ "$type" = "gid" ]; then command_name="getent group"; else command_name="getent passwd"; fi

    while ${command_name} "${current_id}" >/dev/null 2>&1; do
        ((current_id++))
    done
    echo "$current_id"
}

create_mediacenter_users() {
    log_info "Calculating UIDs and GIDs for isolation..."
    
    # Base GID for the 'mediacenter' group
    MEDIACENTER_GID=$(find_available_id gid 13000)
    
    # Calculate unique UIDs starting from a base
    BASE_UID=$(find_available_id uid 13001)
    
    # Define users and their UIDs dynamically
    declare -g RCLONE_UID=$BASE_UID
    declare -g ZURG_UID=$((BASE_UID + 1))
    declare -g DECYPHARR_UID=$((BASE_UID + 2))
    declare -g SONARR_UID=$((BASE_UID + 3))
    declare -g RADARR_UID=$((BASE_UID + 4))
    declare -g PROWLARR_UID=$((BASE_UID + 5))
    declare -g OVERSEERR_UID=$((BASE_UID + 6))
    declare -g PLEX_UID=$((BASE_UID + 7))
    declare -g POSTGRES_UID=$((BASE_UID + 8))
    declare -g HOMARR_UID=$((BASE_UID + 9))

    # Create Group
    log_info "Creating mediacenter group (GID: $MEDIACENTER_GID)..."
    if ! getent group mediacenter >/dev/null; then
        sudo groupadd -r -g "$MEDIACENTER_GID" mediacenter
        log_success "Group 'mediacenter' created."
    else
        log_warning "Group 'mediacenter' already exists."
    fi

    # Create Users
    local users=(
        "rclone $RCLONE_UID" "zurg $ZURG_UID" "decypharr $DECYPHARR_UID" "sonarr $SONARR_UID"
        "radarr $RADARR_UID" "prowlarr $PROWLARR_UID" "overseerr $OVERSEERR_UID"
        "plex $PLEX_UID" "homarr $HOMARR_UID"
    )

    for user_data in "${users[@]}"; do
        read -r username uid <<< "$user_data"
        if ! getent passwd "$username" >/dev/null; then
            sudo useradd -r -u "$uid" -g "$MEDIACENTER_GID" -s /usr/sbin/nologin -c "Media Stack Service User" "$username"
            log_info "Created service user: $username (UID: $uid)"
        else
            log_warning "Service user $username already exists."
        fi
    done
    
    # Add current user to docker and mediacenter groups for permission fixes later
    log_info "Adding current user ($USER) to 'docker' and 'mediacenter' groups..."
    sudo usermod -aG docker "$USER"
    sudo usermod -aG mediacenter "$USER"
}

# --- Installation/Config Functions ---

install_docker_deps() {
    log_section "1. Installing Docker and Prerequisites"
    
    log_info "Updating system packages..."
    sudo apt update -y
    
    log_info "Installing prerequisites..."
    sudo apt install -y curl git apt-transport-https ca-certificates software-properties-common
    
    log_info "Adding Docker GPG key and repository..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    log_info "Installing Docker Engine and Compose Plugin..."
    sudo apt update -y
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    log_success "Docker Installation Complete."
    log_warning "NOTE: You must LOG OUT and LOG IN (or use 'newgrp docker') for the user group changes to fully apply!"
}

install_cloudflared_client() {
    log_section "2. Installing cloudflared Client"
    
    # Download the ARM64 or AMD64 binary based on system architecture
    if [ "$(uname -m)" = "aarch64" ]; then ARCH="arm64"; else ARCH="amd64"; fi
    
    log_info "Downloading cloudflared for architecture: ${ARCH}..."
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb
    
    log_info "Installing cloudflared package..."
    sudo dpkg -i cloudflared.deb
    rm cloudflared.deb
    
    log_success "cloudflared installed."
}

get_config_input() {
    log_section "3. Interactive Configuration Input"
    
    # --- Collect User Variables ---
    
    read -rp "Enter your main Cloudflare Domain (e.g., example.com): " DOMAIN_NAME
    read -rp "Enter the Cloudflare Tunnel Name (e.g., media-tunnel): " TUNNEL_NAME
    read -rp "Enter the Cloudflare Tunnel ID (UUID) you created previously: " TUNNEL_UUID
    
    read -rp "Enter your Real-Debrid API Token (REQUIRED): " REALDEBRID_TOKEN
    
    DEFAULT_ROOT_DIR="/opt/mediacenter"
    read -rp "Enter the root installation path [${DEFAULT_ROOT_DIR}]: " ROOT_DIR
    ROOT_DIR=${ROOT_DIR:-$DEFAULT_ROOT_DIR}
    
    read -rp "Enter your Timezone (e.g., Europe/Madrid): " TIMEZONE
    TIMEZONE=${TIMEZONE:-Europe/Madrid}
    
    # --- Create Directories ---
    log_info "Creating directory structure in $ROOT_DIR..."
    sudo mkdir -p "${ROOT_DIR}/config"/{plex,sonarr,radarr,prowlarr,overseerr,zurg,decypharr,postgres,homarr}
    sudo mkdir -p "${ROOT_DIR}/data"/{movies,tv,downloads,rclone_mount}
    
    # --- Set Permissions (Important for Docker) ---
    log_info "Setting base directory ownership to current user ($USER) and group 'mediacenter'..."
    sudo chown -R $USER:mediacenter "$ROOT_DIR"
    sudo chmod -R 775 "$ROOT_DIR"
}

generate_files() {
    log_section "4. Generating Configuration Files"
    
    # Create the base .env file
    log_info "Generating .env file..."
    cat <<EOF > .env
# =============================================================================
# ENVIRONMENT VARIABLES - GENERATED BY SCRIPT
# =============================================================================
ROOT_DIR=${ROOT_DIR}
TIMEZONE=${TIMEZONE}
REALDEBRID_TOKEN=${REALDEBRID_TOKEN}

# User/Group IDs (calculated dynamically)
MEDIACENTER_GID=${MEDIACENTER_GID}
RCLONE_UID=${RCLONE_UID}
ZURG_UID=${ZURG_UID}
DECYPHARR_UID=${DECYPHARR_UID}
SONARR_UID=${SONARR_UID}
RADARR_UID=${RADARR_UID}
PROWLARR_UID=${PROWLARR_UID}
OVERSEERR_UID=${OVERSEERR_UID}
PLEX_UID=${PLEX_UID}
HOMARR_UID=${HOMARR_UID}

# Plex Claim Token (Leave blank if claiming manually)
PLEX_CLAIM=
EOF
    log_success "Created .env file."

    # Generate Zurg config (required by Zurg container)
    log_info "Generating Zurg configuration file..."
    cat <<EOF | sudo tee "${ROOT_DIR}/config/zurg/config.yml" > /dev/null
# Zurg - Real-Debrid WebDAV Configuration
zurg: v1
token: ${REALDEBRID_TOKEN}
host: "[::]"
port: 9999
check_for_changes_every_secs: 60
retain_rd_torrent_name: true
directories:
  torrents:
    group: 1
    filters:
      - regex: /.*/
EOF
    sudo chown zurg:mediacenter "${ROOT_DIR}/config/zurg/config.yml"
    log_success "Created Zurg config."

    # Generate Rclone config (required by Rclone container)
    log_info "Generating Rclone configuration file..."
    cat <<EOF > "${ROOT_DIR}/config/rclone.conf"
[zurg]
type = webdav
url = http://zurg:9999/dav
vendor = other
pacer_min_sleep = 0
EOF
    sudo chown rclone:mediacenter "${ROOT_DIR}/config/rclone.conf"
    log_success "Created Rclone config."

    # Generate Docker Compose (HEREDOC)
    log_info "Generating docker-compose.yml with 11 core services..."
    cat <<EOF > docker-compose.yml
version: "3.9"

# Core Network Definition
networks:
  mediacenter:
    name: mediacenter
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.0.0/24
          gateway: 172.30.0.1

volumes:
  postgres_data:
    driver: local
  zurg_data:
    driver: local

services:
# --- 1. ZURG (Real-Debrid WebDAV) ---
  zurg:
    image: ghcr.io/debridmediamanager/zurg-testing:latest
    container_name: zurg
    env_file: .env
    networks:
      mediacenter:
        ipv4_address: 172.30.0.5
    environment:
      - TZ=\${TIMEZONE}
    volumes:
      - ${ROOT_DIR}/config/zurg/config.yml:/app/config.yml
      - zurg_data:/app/data
    restart: on-failure
    healthcheck:
      test: ["CMD", "curl", "-f", "localhost:9999/dav/version.txt"]
      interval: 30s
      timeout: 10s
      retries: 5

# --- 2. RCLONE (Mount Zurg WebDAV) ---
  rclone:
    image: rclone/rclone:latest
    container_name: rclone
    env_file: .env
    networks:
      mediacenter:
        ipv4_address: 172.30.0.6
    environment:
      - PUID=\${RCLONE_UID}
      - PGID=\${MEDIACENTER_GID}
      - TZ=\${TIMEZONE}
    volumes:
      - ${ROOT_DIR}/data/rclone_mount:/data:rshared
      - ${ROOT_DIR}/config/rclone.conf:/config/rclone/rclone.conf
    cap_add: [SYS_ADMIN]
    security_opt: [apparmor:unconfined]
    devices: [/dev/fuse]
    command: >
      mount zurg: /data
      --allow-non-empty --allow-other
      --uid=\${RCLONE_UID} --gid=\${MEDIACENTER_GID}
      --dir-cache-time=15s --poll-interval=15s
    restart: on-failure
    healthcheck:
      test: ["CMD", "sh", "-c", "mountpoint -q /data"] # Check if FUSE mount is active
      interval: 10s
      timeout: 5s
      retries: 5
    depends_on:
      zurg: { condition: service_healthy }

# --- 3. PLEX MEDIA SERVER ---
  plex:
    image: lscr.io/linuxserver/plex:latest
    container_name: plex
    env_file: .env
    network_mode: host # REQUIRED for Plex auto-discovery
    environment:
      - PUID=\${PLEX_UID}
      - PGID=\${MEDIACENTER_GID}
      - TZ=\${TIMEZONE}
      - PLEX_CLAIM=\${PLEX_CLAIM}
    volumes:
      - ${ROOT_DIR}/config/plex:/config
      - ${ROOT_DIR}/data/movies:/movies
      - ${ROOT_DIR}/data/tv:/tv
      # Mount the Rclone mount point directly into Plex
      - ${ROOT_DIR}/data/rclone_mount:/media_stream:ro 
    restart: unless-stopped
    depends_on:
      rclone: { condition: service_started }

# --- 4. SONARR (TV Management) ---
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    env_file: .env
    networks: [mediacenter]
    environment:
      - PUID=\${SONARR_UID}
      - PGID=\${MEDIACENTER_GID}
      - TZ=\${TIMEZONE}
    volumes:
      - ${ROOT_DIR}/config/sonarr:/config
      - ${ROOT_DIR}/data/tv:/tv
      - ${ROOT_DIR}/data/downloads:/downloads # Downloads folder for clients
    ports: [8989:8989]
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8989/ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    depends_on:
      prowlarr: { condition: service_started }

# --- 5. RADARR (Movie Management) ---
  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    env_file: .env
    networks: [mediacenter]
    environment:
      - PUID=\${RADARR_UID}
      - PGID=\${MEDIACENTER_GID}
      - TZ=\${TIMEZONE}
    volumes:
      - ${ROOT_DIR}/config/radarr:/config
      - ${ROOT_DIR}/data/movies:/movies
      - ${ROOT_DIR}/data/downloads:/downloads # Downloads folder for clients
    ports: [7878:7878]
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:7878/ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    depends_on:
      prowlarr: { condition: service_started }

# --- 6. PROWLARR (Indexer Manager) ---
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:develop
    container_name: prowlarr
    env_file: .env
    networks: [mediacenter]
    environment:
      - PUID=\${PROWLARR_UID}
      - PGID=\${MEDIACENTER_GID}
      - TZ=\${TIMEZONE}
    volumes:
      - ${ROOT_DIR}/config/prowlarr:/config
    ports: [9696:9696]
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9696/ping"]
      interval: 10s
      timeout: 5s
      retries: 5

# --- 7. DECYPHARR (Real-Debrid Download Client) ---
  decypharr:
    image: cy01/blackhole:beta
    container_name: decypharr
    env_file: .env
    networks: [mediacenter]
    environment:
      - PUID=\${DECYPHARR_UID}
      - PGID=\${MEDIACENTER_GID}
      - TZ=\${TIMEZONE}
    volumes:
      - ${ROOT_DIR}/config/decypharr:/app
      - ${ROOT_DIR}/data:/data # Full data path exposed
      # Mount propagation for FUSE / Rclone mount
      - ${ROOT_DIR}/data/rclone_mount:/mnt/realdebrid:rshared
    ports: [8283:8282] # Host:Container
    restart: on-failure
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8282/api/status"] # Assuming Decypharr has a status endpoint on port 8282
      interval: 10s
      timeout: 5s
      retries: 5
    depends_on:
      zurg: { condition: service_healthy }
      rclone: { condition: service_healthy }

# --- 8. OVERSEERR (Request Management) ---
  overseerr:
    image: sctx/overseerr:latest
    container_name: overseerr
    env_file: .env
    networks: [mediacenter]
    environment:
      - PUID=\${OVERSEERR_UID}
      - PGID=\${MEDIACENTER_GID}
      - TZ=\${TIMEZONE}
    volumes:
      - ${ROOT_DIR}/config/overseerr:/app/config
    ports: [5055:5055]
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "-q", "--timeout=3", "--tries=1", "--spider", "http://localhost:5055"]
      interval: 10s
      timeout: 5s
      retries: 5
    depends_on:
      plex: { condition: service_started }

# --- 9. HOMARR (Dashboard) ---
  homarr:
    image: ghcr.io/homarr-labs/homarr:latest
    container_name: homarr
    env_file: .env
    networks: [mediacenter]
    environment:
      - PUID=\${HOMARR_UID}
      - PGID=\${MEDIACENTER_GID}
      - TZ=\${TIMEZONE}
    volumes:
      - ${ROOT_DIR}/config/homarr:/app/data/configs
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports: [7575:7575]
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "ps aux | grep -v grep | grep -q next-server || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5

# --- 10. WATCHTOWER (Auto Updates) ---
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    env_file: .env
    networks: [mediacenter]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_SCHEDULE=0 0 4 * * * # Daily at 4 AM
      - TZ=\${TIMEZONE}
    restart: unless-stopped

# --- 11. ZILEAN POSTGRES (DB for Indexer) ---
  zilean-postgres:
    image: postgres:17.1
    container_name: zilean-postgres
    env_file: .env
    networks: [mediacenter]
    environment:
      - TZ=\${TIMEZONE}
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_DB=zilean
    volumes:
      - postgres_data:/var/lib/postgresql/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready --username=postgres --dbname=zilean"]
      start_period: 10s
      interval: 5s
      timeout: 4s
      retries: 5
EOF
    log_success "Created docker-compose.yml with 11 core services."

    # Generate Cloudflare Tunnel config
    log_info "Generating Cloudflare Tunnel routing configuration..."
    sudo mkdir -p /etc/cloudflared
    
    cat <<EOF | sudo tee /etc/cloudflared/config.yml > /dev/null
tunnel: ${TUNNEL_UUID}
credentials-file: /etc/cloudflared/${TUNNEL_UUID}.json

ingress:
  - hostname: plex.${DOMAIN_NAME}
    service: http://localhost:32400
  - hostname: sonarr.${DOMAIN_NAME}
    service: http://localhost:8989
  - hostname: radarr.${DOMAIN_NAME}
    service: http://localhost:7878
  - hostname: prowlarr.${DOMAIN_NAME}
    service: http://localhost:9696
  - hostname: overseerr.${DOMAIN_NAME}
    service: http://localhost:5055
  - hostname: decypharr.${DOMAIN_NAME}
    service: http://localhost:8283
  - hostname: home.${DOMAIN_NAME}
    service: http://localhost:7575
  - service: http_status:404
EOF
    log_success "Created Cloudflare config.yml."
    
    # Move credentials file if it exists (from manual login step)
    CRED_FILE_PATH="${HOME}/.cloudflared/${TUNNEL_UUID}.json"
    if [ -f "$CRED_FILE_PATH" ]; then
        log_info "Copying tunnel credentials to system location..."
        sudo mv "$CRED_FILE_PATH" "/etc/cloudflared/"
        log_success "Credentials moved."
    else
        log_warning "Could not find credentials file: ${CRED_FILE_PATH}. Did you run 'cloudflared tunnel login' and 'cloudflared tunnel create'?"
    fi
}

# --- DNS Creation Function ---

create_cloudflare_dns_records() {
    log_section "5.2 Creating Cloudflare DNS Records"
    
    # List of service names (which become subdomains)
    local subdomains=(
        "plex" "sonarr" "radarr" "prowlarr" "overseerr" "decypharr" "home"
    )

    log_info "Creating CNAME records for services pointed to tunnel ${TUNNEL_NAME}..."

    for service in "${subdomains[@]}"; do
        local subdomain="${service}.${DOMAIN_NAME}"
        if [ "$service" == "home" ]; then
            subdomain="home.${DOMAIN_NAME}" # Homarr dashboard
        fi
        
        log_info "-> Routing DNS for ${subdomain}..."
        
        # cloudflared tunnel route dns command creates a CNAME record pointing 
        # the subdomain to the tunnel ID (e.g., example.com.cfargotunnel.com)
        if cloudflared tunnel route dns "${TUNNEL_NAME}" "${subdomain}"; then
            log_success "Record created successfully for ${subdomain}."
        else
            # This often fails if the record already exists, which is acceptable.
            log_warning "Could not create DNS record for ${subdomain}. It might already exist, or the tunnel is not authenticated."
        fi
    done
    log_success "DNS routing attempts complete."
}

# --- Waiting Function ---
wait_for_critical_services() {
    local services_to_check=("zurg" "rclone" "sonarr" "radarr" "prowlarr" "decypharr")
    local timeout=300 # 5 minutes total timeout
    local interval=10
    local elapsed=0
    
    log_section "5.1 Waiting for Core Services to be Healthy"
    log_info "Giving containers time to stabilize (up to 5 minutes)..."

    while [ "$elapsed" -lt "$timeout" ]; do
        local unhealthy_count=0
        local unhealthy_list=""

        for service in "${services_to_check[@]}"; do
            # Check container health status
            local status=$(docker inspect -f '{{.State.Health.Status}}' "$service" 2>/dev/null || echo "not_found")
            
            # If status is not 'healthy', check if it's actually running before counting
            if [ "$status" != "healthy" ]; then
                local running_status=$(docker inspect -f '{{.State.Running}}' "$service" 2>/dev/null || echo "false")
                
                if [ "$running_status" = "true" ]; then
                    unhealthy_count=$((unhealthy_count + 1))
                    unhealthy_list="${unhealthy_list} ${service}(${status})"
                fi
            fi
        done

        if [ "$unhealthy_count" -eq 0 ]; then
            log_success "All critical services are now healthy or fully running."
            return 0
        fi

        # Log status every 30 seconds
        if [ $((elapsed % 30)) -eq 0 ]; then
            log_warning "${unhealthy_count} service(s) still initializing: ${unhealthy_list}"
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_error "Critical services failed to become healthy within ${timeout}s."
    log_error "Please check container logs: docker compose logs"
    return 1
}

# --- Deployment Function ---
deploy_stack_and_tunnel() {
    log_section "5. Deployment and Cloudflare Activation"
    
    # 5a. Confirmation Prompt
    echo ""
    echo "################################################################"
    echo "# STEP 5A: CONFIRM MANUAL ACTIONS COMPLETE                     #"
    echo "################################################################"
    echo ""
    log_info "Before continuing, please confirm you have completed the two manual steps:"
    log_info "1. Logged out and logged back in (or ran 'newgrp mediacenter')."
    log_info "2. Ran 'cloudflared tunnel login' and completed the browser authentication."
    
    read -rp "Have you completed both manual steps? (y/N): " CONFIRMATION
    
    if [[ ! "$CONFIRMATION" =~ ^[Yy]$ ]]; then
        log_error "Confirmation failed. Installation aborted. Please complete the manual steps and run this command again."
        exit 1
    fi
    
    # 5b. Start Docker stack
    log_info "Starting Docker containers with 'docker compose up -d'..."
    docker compose up -d
    
    if [ $? -ne 0 ]; then
        log_error "Docker Compose failed to start. Check logs with 'docker compose logs'."
        exit 1
    fi
    log_success "All media services started."
    
    # 5c. Wait for stability
    if ! wait_for_critical_services; then
        log_error "Deployment failed because critical services did not stabilize."
        log_error "The stack is running, but unstable. Check logs and restart manually later."
        exit 1
    fi

    # 5d. Create DNS Records
    create_cloudflare_dns_records

    # 5e. Install and start Cloudflare Tunnel Service
    log_info "Installing Cloudflare Tunnel as a system service..."
    sudo cloudflared tunnel install "${TUNNEL_NAME}"
    
    log_info "Starting Cloudflare Tunnel service..."
    sudo systemctl start cloudflared
    
    log_info "Checking tunnel status..."
    sudo systemctl status cloudflared --no-pager | grep "Active"
    
    log_success "Deployment Complete! Your stack is now accessible via Cloudflare."
}

# --- Main Script Execution Flow ---

# Create a temporary working directory for compose files
mkdir -p ~/unified-stack-temp
cd ~/unified-stack-temp

# Run steps
install_docker_deps
create_mediacenter_users
install_cloudflared_client
get_config_input
generate_files

# --- Final Manual Steps Reminder ---
log_section "IMPORTANT: Installation Breakpoint & Resume"

echo "The first stage of setup is complete (Docker, cloudflared, users created)."
echo ""
echo "#####################################################################"
echo "# ACTION REQUIRED: LOGOUT/LOGIN & CLOUDFLARE AUTHENTICATION         #"
echo "#####################################################################"
echo ""
echo "To finish the installation, you MUST do two manual steps:"
echo ""
echo "1. Apply Permissions: You were added to the 'docker' and 'mediacenter' groups."
echo "   -> Please **LOG OUT** of your current SSH session and **LOG BACK IN**."
echo "   -> (Alternatively, run: newgrp mediacenter)"
echo ""
echo "2. Authenticate Cloudflare: This requires a browser interaction."
echo "   -> Run the command: ${COLOR_YELLOW}cloudflared tunnel login${COLOR_RESET}"
echo "   -> Follow the link in your browser to log in and select your domain."
echo ""
echo "Once both steps are done, run the following commands to FINISH the install:"
echo ""
echo -e "${COLOR_GREEN}cd ~/unified-stack-temp${COLOR_RESET}"
echo -e "${COLOR_GREEN}deploy_stack_and_tunnel${COLOR_RESET}"
echo ""
echo "The script will now EXIT. Rerun the two commands above after you log back in."

# Exit here to force logout/login break
exit 0
