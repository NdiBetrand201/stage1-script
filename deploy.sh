#!/bin/bash

# deploy.sh - Automated Deployment of FastAPI App to AWS EC2

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Initialize logging to a timestamped file
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Error handling trap
trap 'log "${RED}ERROR: Script failed at line $LINENO${NC}"; exit 1' ERR

# Cleanup function for --cleanup flag
cleanup() {
    log "Initiating cleanup..."
    ssh -i ~/.ssh/HNG13_stage1_betrand.pem "$SSH_USER@$SERVER_IP" << 'EOF'
        set -e
        log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
        log "Stopping and removing containers..."
        docker-compose -f /tmp/project_dir/docker-compose.yml down 2>/dev/null || true
        docker stop fastapi-container 2>/dev/null || true
        docker rm fastapi-container 2>/dev/null || true
        docker system prune -f 2>/dev/null || true
        log "Removing project directory..."
        rm -rf /tmp/project_dir 2>/dev/null || true
        log "Reloading Nginx..."
        sudo systemctl restart nginx 2>/dev/null || true
EOF
    log "${GREEN}Cleanup completed successfully${NC}"
    exit 0
}

# Check for cleanup flag
if [ "${1:-}" = "--cleanup" ]; then
    cleanup
fi

# 1. Collect Parameters
log "Collecting user input..."
read -p "Enter Git Repository URL: " GIT_URL
read -sp "Enter Personal Access Token: " GIT_PAT
echo
read -p "Enter Branch Name (default: main): " GIT_BRANCH
GIT_BRANCH=${GIT_BRANCH:-main}
read -p "Enter SSH Username: " SSH_USER
read -p "Enter Server IP: " SERVER_IP
read -p "Enter SSH Key Path: " SSH_KEY
read -p "Enter Application Port: " APP_PORT

# Validate inputs
if [ -z "$GIT_URL" ] || [ -z "$GIT_PAT" ] || [ -z "$SSH_USER" ] || [ -z "$SERVER_IP" ] || [ -z "$SSH_KEY" ] || [ -z "$APP_PORT" ]; then
    log "${RED}ERROR: All inputs are required${NC}"
    exit 1
fi

# Validate SSH key exists and has correct permissions
if [ ! -f "$SSH_KEY" ]; then
    log "${RED}ERROR: SSH key not found at $SSH_KEY${NC}"
    exit 1
fi

# Add server to known_hosts to avoid prompt
log "Adding server to known_hosts..."
ssh-keyscan -H "$SERVER_IP" >> ~/.ssh/known_hosts 2>/dev/null

# Check permissions (skip on Windows/Git Bash)
if [[ ! "$OSTYPE" =~ ^(msys|win32|cygwin)$ ]]; then
    KEY_PERMS="$(stat -c %a "$SSH_KEY" 2>/dev/null || stat -f %Lp "$SSH_KEY" 2>/dev/null)"
    if [ "$KEY_PERMS" != "400" ] && [ "$KEY_PERMS" != "600" ]; then
        log "WARNING: SSH key permissions are $KEY_PERMS (should be 400 or 600)"
        log "Attempting to fix permissions..."
        chmod 400 "$SSH_KEY" 2>/dev/null || log "WARNING: Could not change permissions. Continuing anyway..."
    fi
else
    log "Running on Windows - skipping permission check"
fi

# 2. Clone Repository
log "Cloning repository..."
REPO_NAME=$(basename "$GIT_URL" .git)

# Parse Git URL and create authenticated URL
GIT_URL_CLEAN="${GIT_URL#https://}"
GIT_URL_CLEAN="${GIT_URL_CLEAN#http://}"
AUTH_URL="https://${GIT_PAT}@${GIT_URL_CLEAN}"

if [ -d "$REPO_NAME" ]; then
    log "Repository exists, pulling latest changes..."
    cd "$REPO_NAME"
    git pull "$AUTH_URL" "$GIT_BRANCH"
else
    git clone -b "$GIT_BRANCH" "$AUTH_URL" "$REPO_NAME"
    cd "$REPO_NAME"
fi

# 3. Verify Dockerfile or docker-compose.yml
log "Verifying project files..."
if [ ! -f "Dockerfile" ] && [ ! -f "docker-compose.yml" ]; then
    log "${RED}ERROR: Dockerfile or docker-compose.yml not found${NC}"
    exit 1
fi

# 4. Test SSH Connection
log "Testing SSH connection..."
if ! ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$SERVER_IP" true; then
    log "${RED}ERROR: SSH connection failed${NC}"
    exit 1
fi

# 5. Prepare Remote Environment
log "Preparing remote environment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << 'EOF'
    set -e
    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
    log "Updating system packages..."
    sudo apt-get update -y && sudo apt-get upgrade -y
    log "Installing Docker..."
    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker "$USER"
    fi
    log "Installing Docker Compose..."
    if ! command -v docker-compose >/dev/null 2>&1; then
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
    log "Installing Nginx..."
    sudo apt-get install -y nginx
    sudo systemctl enable docker nginx
    sudo systemctl start docker nginx
    log "Disabling default Nginx config to avoid conflicts..."
    sudo rm -f /etc/nginx/sites-enabled/default
    log "Verifying installations..."
    docker --version
    docker-compose --version
    nginx -v
EOF

# 6. Deploy Application
log "Deploying application..."
# Clean up old deployment directory first
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << 'EOF'
    set -e
    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
    log "Cleaning up old deployment directory..."
    rm -rf /tmp/project_dir
    mkdir -p /tmp/project_dir
EOF

log "Copying application files..."
scp -i "$SSH_KEY" -r . "$SSH_USER@$SERVER_IP:/tmp/project_dir"

ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << EOF
    set -e
    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] \$1"; }
    cd /tmp/project_dir
    if [ -f docker-compose.yml ]; then
        log "Running docker-compose..."
        docker-compose up -d --build
    else
        log "Building and running Docker container..."
        docker build -t fastapi-app .
        docker stop fastapi-container 2>/dev/null || true
        docker rm fastapi-container 2>/dev/null || true
        docker run -d --name fastapi-container -p $APP_PORT:$APP_PORT fastapi-app
    fi
    log "Verifying container health..."
    sleep 5
    if ! docker ps | grep -q fastapi-container; then
        log "ERROR: Container is not running"
        exit 1
    fi
EOF

# 7. Configure Nginx as a Reverse Proxy
log "Configuring Nginx..."
NGINX_CONF="/etc/nginx/sites-available/fastapi-app"
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << EOF
    set -e
    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] \$1"; }
    sudo bash -c "cat > $NGINX_CONF" << 'NGINX'
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://localhost:$APP_PORT;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
    }
}
NGINX
    sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
    log "Testing Nginx configuration..."
    if ! sudo nginx -t; then
        log "ERROR: Nginx configuration test failed"
        exit 1
    fi
    sudo systemctl reload nginx
EOF

# 8. Validate Deployment
log "Validating deployment..."
ssh -i "$SSH_KEY" "$SSH_USER@$SERVER_IP" << EOF
    set -e
    APP_PORT=$APP_PORT
    log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] \$1"; }
    log "Checking Docker service..."
    systemctl is-active --quiet docker || { log "ERROR: Docker service not running"; exit 1; }
    log "Checking container status..."
    docker ps | grep -q fastapi-container || { log "ERROR: Container not running"; exit 1; }
    log "Testing endpoint..."
    if ! curl -s -f http://localhost:\$APP_PORT >/dev/null; then
        log "ERROR: Application not accessible"
        exit 1
    fi
EOF

# Local validation
log "Performing local validation..."
if ! curl -s -f "http://$SERVER_IP" >/dev/null; then
    log "${RED}ERROR: Application not accessible remotely${NC}"
    exit 1
fi

log "${GREEN}Deployment completed successfully!${NC}"
log "Application is accessible at: http://$SERVER_IP"
