#!/bin/bash

# Nginx User Setup Script
# Setup user + shared media directory for SFTP uploads
# Target: Ubuntu 24.04
# Options:
#   --username NAME      Ubuntu username (default: avdb)
#   --password PASS      Ubuntu password (default: avdb2026)
#   --storage-path DIR   Media root directory (default: /home/files)
#   --group NAME         Shared group name (default: www-data)
#   --uninstall          Remove user and configuration
#   -h, --help           Show this help message

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
UNINSTALL=false
UBUNTU_USER="vdohide"
UBUNTU_PASSWORD="[PASSWORD]"
STORAGE_PATH="/home/files"
SHARED_GROUP="www-data"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        --username)
            UBUNTU_USER="$2"
            shift 2
            ;;
        --password)
            UBUNTU_PASSWORD="$2"
            shift 2
            ;;
        --storage-path)
            STORAGE_PATH="$2"
            shift 2
            ;;
        --group)
            SHARED_GROUP="$2"
            shift 2
            ;;
        -h|--help)
            echo "Nginx User Setup Script"
            echo ""
            echo "Options:"
            echo "  --uninstall          Remove user and configuration"
            echo "  --username NAME      Ubuntu username (default: avdb)"
            echo "  --password PASS      Ubuntu password (default: avdb2026)"
            echo "  --storage-path DIR   Media root directory (default: /home/files)"
            echo "  --group NAME         Shared group name (default: www-data)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Examples:"
            echo "  # Install with defaults"
            echo "  curl -fsSL .../install.sh | sudo -E bash"
            echo ""
            echo "  # Install with custom user and path"
            echo "  curl -fsSL .../install.sh | sudo -E bash -s -- --username myuser --password mypass --storage-path /data/media"
            echo ""
            echo "  # Uninstall"
            echo "  curl -fsSL .../install.sh | sudo -E bash -s -- --uninstall --username myuser --storage-path /data/media"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

# Functions
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ==========================================
# Uninstallation
# ==========================================
if [ "$UNINSTALL" = true ]; then
    print_warning "⚠️  Starting Uninstallation..."

    # Remove ACLs from media directory
    if [ -d "$STORAGE_PATH" ]; then
        print_status "Removing ACLs from ${STORAGE_PATH}..."
        if command -v setfacl > /dev/null 2>&1; then
            setfacl -R -b "$STORAGE_PATH" 2>/dev/null || true
        fi
    fi

    # Remove user
    if id -u "$UBUNTU_USER" >/dev/null 2>&1; then
        print_status "Removing user: ${UBUNTU_USER}..."
        userdel -r "$UBUNTU_USER" 2>/dev/null || userdel "$UBUNTU_USER" 2>/dev/null || true
    else
        print_warning "User ${UBUNTU_USER} does not exist."
    fi

    print_status "✅ Uninstallation completed successfully!"
    print_warning "Note: Media directory ${STORAGE_PATH} was NOT removed. Remove it manually if needed."
    exit 0
fi

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
fi

print_status "Setting up user '${UBUNTU_USER}' with storage path '${STORAGE_PATH}'..."

# Create or update user
print_status "Create or update user: ${UBUNTU_USER}"
if id -u "$UBUNTU_USER" >/dev/null 2>&1; then
    print_status "User exists — resetting password and ensuring groups"
else
    adduser --disabled-password --gecos "" "$UBUNTU_USER"
fi

# Set password
echo "${UBUNTU_USER}:${UBUNTU_PASSWORD}" | chpasswd

# Add to sudo and shared group
usermod -aG sudo "$UBUNTU_USER"
usermod -aG "$SHARED_GROUP" "$UBUNTU_USER"

# Prepare media directory
print_status "Prepare media directory: ${STORAGE_PATH}"
mkdir -p "$STORAGE_PATH"

# Set ownership
chown -R "${UBUNTU_USER}:${SHARED_GROUP}" "$STORAGE_PATH"

# Set permissions: 2775 = rwx for owner+group, r-x for others, setgid for auto group inheritance
chmod -R 2775 "$STORAGE_PATH"

# Set default ACL so new files/dirs inherit group-write
if command -v setfacl >/dev/null 2>&1; then
    setfacl -R -m d:g:${SHARED_GROUP}:rwx -m g:${SHARED_GROUP}:rwx "$STORAGE_PATH" || true
else
    print_status "Installing acl package..."
    apt-get update -y && apt-get install -y acl
    setfacl -R -m d:g:${SHARED_GROUP}:rwx -m g:${SHARED_GROUP}:rwx "$STORAGE_PATH" || true
fi

# Quick test write
print_status "Quick test write as ${UBUNTU_USER}"
sudo -u "$UBUNTU_USER" bash -lc "touch '${STORAGE_PATH}/__test_write__.tmp' && rm -f '${STORAGE_PATH}/__test_write__.tmp'"
print_status "OK: ${UBUNTU_USER} can write to ${STORAGE_PATH}"

# Display connection information
print_status "✅ Installation completed successfully!"
print_status "Service Information:"
cat <<EOF

User:     ${UBUNTU_USER}
Group:    ${SHARED_GROUP}
Storage:  ${STORAGE_PATH}

SFTP/WinSCP Connection:
  Host:     <YOUR_SERVER_IP>
  Protocol: SFTP
  Port:     22
  Username: ${UBUNTU_USER}
  Password: ${UBUNTU_PASSWORD}

EOF