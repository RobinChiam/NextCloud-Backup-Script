#!/bin/bash

# NextCloud Docker Backup Script
# This script backs up NextCloud data, config, and database
# Author: Generated for NextCloud VM backup
# Date: 1st June 2025

# Load Environment Variables
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

# Configuration
BACKUP_DATE=$(date +"%Y%m%d_%H%M%S")
LOCAL_BACKUP_DIR="/tmp/nextcloud_backup_${BACKUP_DATE}"
REMOTE_BACKUP_DIR="/home/${REMOTE_USER}/backup/nextcloud"
RETENTION_DAYS=7

# Docker container names
DB_CONTAINER="nextcloud_db"
NC_CONTAINER="nextcloud_app"

# Database credentials (from docker-compose)
DB_NAME="nextcloud-db"
DB_USER="nextcloud"

# Log file
LOG_FILE="/var/log/nextcloud_backup.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Error handling
handle_error() {
    log "${RED}ERROR: $1${NC}"
    cleanup
    exit 1
}

# Cleanup function
cleanup() {
    log "${YELLOW}Cleaning up temporary files...${NC}"
    rm -rf "$LOCAL_BACKUP_DIR"
}

# Check if required commands exist
check_requirements() {
    local commands=("docker" "ssh" "rsync" "tar" "gzip")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            handle_error "Required command '$cmd' not found"
        fi
    done
    
    # Check if SSH key exists
    if [ ! -f "$SSH_KEY" ]; then
        handle_error "SSH key not found at $SSH_KEY"
    fi
    
    # Check SSH key permissions
    local key_perms=$(stat -c "%a" "$SSH_KEY")
    if [ "$key_perms" != "600" ]; then
        log "${YELLOW}Setting correct permissions on SSH key...${NC}"
        chmod 600 "$SSH_KEY" || handle_error "Failed to set SSH key permissions"
    fi
}

# Check if containers are running
check_containers() {
    if ! docker ps | grep -q "$DB_CONTAINER"; then
        handle_error "Database container '$DB_CONTAINER' is not running"
    fi
    
    if ! docker ps | grep -q "$NC_CONTAINER"; then
        handle_error "NextCloud container '$NC_CONTAINER' is not running"
    fi
}

# Create backup directory
create_backup_dir() {
    log "${YELLOW}Creating local backup directory: $LOCAL_BACKUP_DIR${NC}"
    mkdir -p "$LOCAL_BACKUP_DIR" || handle_error "Failed to create backup directory"
}

# Enable NextCloud maintenance mode
enable_maintenance_mode() {
    log "${YELLOW}Enabling NextCloud maintenance mode...${NC}"
    docker exec -u www-data "$NC_CONTAINER" php occ maintenance:mode --on || \
        handle_error "Failed to enable maintenance mode"
}

# Disable NextCloud maintenance mode
disable_maintenance_mode() {
    log "${YELLOW}Disabling NextCloud maintenance mode...${NC}"
    docker exec -u www-data "$NC_CONTAINER" php occ maintenance:mode --off || \
        log "${RED}WARNING: Failed to disable maintenance mode${NC}"
}

# Backup database
backup_database() {
    log "${YELLOW}Backing up MariaDB database...${NC}"
    
    # Run mysqldump from within the container and pipe to gzip
    docker exec "$DB_CONTAINER" mysqldump \
        -u "$DB_USER" \
        -p'$DB_PASS' \
        --single-transaction \
        --routines \
        --triggers \
        --add-drop-database \
        --databases \
        "$DB_NAME" | gzip > "${LOCAL_BACKUP_DIR}/database.sql.gz"
    
    # Check if the backup was successful by verifying the file exists and has content
    if [ ! -f "${LOCAL_BACKUP_DIR}/database.sql.gz" ] || [ ! -s "$LOCAL_BACKUP_DIR/database.sql.gz" ]; then
        handle_error "Database backup failed - backup file is missing or empty"
    fi
    
    # Additional verification - check if the gzipped file contains SQL content
    if ! gunzip -t "${LOCAL_BACKUP_DIR}/database.sql.gz" 2>/dev/null; then
        handle_error "Database backup failed - backup file is corrupted"
    fi
    
    # Get backup file size for logging
    local backup_size=$(du -h "${LOCAL_BACKUP_DIR}/database.sql.gz" | cut -f1)
    log "${GREEN}Database backup completed successfully (Size: $backup_size)${NC}"
}

# Backup NextCloud data
backup_data() {
    log "${YELLOW}Backing up NextCloud data directory...${NC}"
    tar -czf "$LOCAL_BACKUP_DIR/nextcloud_data.tar.gz" \
        -C /mnt nextcloud-data || \
        handle_error "Data backup failed"
    
    log "${GREEN}Data backup completed${NC}"
}

# Backup NextCloud application files and config
backup_app_config() {
    log "${YELLOW}Backing up NextCloud application files and config...${NC}"
    
    # Create temporary directory for docker volume backup
    local temp_dir=$(mktemp -d)
    
    # Backup NextCloud volume (contains config and apps)
    docker run --rm \
        -v nextcloud:/source \
        -v "$temp_dir":/backup \
        alpine:latest \
        tar -czf /backup/nextcloud_app.tar.gz -C /source . || \
        handle_error "Failed to backup NextCloud application files"
    
    # Move the backup to our backup directory
    mv "$temp_dir/nextcloud_app.tar.gz" "$LOCAL_BACKUP_DIR/" || \
        handle_error "Failed to move application backup"
    
    # Cleanup temp directory
    rm -rf "$temp_dir"
    
    log "${GREEN}Application and config backup completed${NC}"
}

# Create backup info file
create_backup_info() {
    log "${YELLOW}Creating backup information file...${NC}"
    cat > "$LOCAL_BACKUP_DIR/backup_info.txt" << EOF
NextCloud Backup Information
============================
Backup Date: $(date)
Backup Type: Full (Data + Database + Config)
Source Host: $(hostname)
NextCloud Version: $(docker exec -u www-data "$NC_CONTAINER" php occ status --output=json | grep -o '"version":"[^"]*' | cut -d'"' -f4)

Files included:
- database.sql.gz (MariaDB dump)
- nextcloud_data.tar.gz (User data from /mnt/nextcloud-data)
- nextcloud_app.tar.gz (Application files and config from Docker volume)

Restore Instructions:
1. Stop NextCloud containers
2. Restore database: gunzip < database.sql.gz | docker exec -i DB_CONTAINER mysql -u USER -pPASSWORD DATABASE
3. Extract data: tar -xzf nextcloud_data.tar.gz -C /mnt/
4. Restore app volume: docker run --rm -v nextcloud:/target -v \$(pwd):/source alpine tar -xzf /source/nextcloud_app.tar.gz -C /target
5. Start containers and run: docker exec -u www-data CONTAINER php occ maintenance:mode --off
EOF
}

# Transfer backup to VPS
transfer_backup() {
    log "${YELLOW}Transferring backup to VPS...${NC}"
    
    # Create remote backup directory if it doesn't exist
    ssh -i "$SSH_KEY" -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_HOST" "mkdir -p '$REMOTE_BACKUP_DIR'" || \
        handle_error "Failed to create remote backup directory"
    
    # Create archive of the entire backup
    local archive_name="nextcloud_backup_${BACKUP_DATE}.tar.gz"
    tar -czf "/tmp/$archive_name" -C "$(dirname "$LOCAL_BACKUP_DIR")" "$(basename "$LOCAL_BACKUP_DIR")" || \
        handle_error "Failed to create backup archive"
    
    # Transfer using rsync for reliability
    rsync -avz --progress -e "ssh -i $SSH_KEY -p $REMOTE_PORT" "/tmp/$archive_name" \
        "$REMOTE_USER@$REMOTE_HOST:$REMOTE_BACKUP_DIR/" || \
        handle_error "Failed to transfer backup to VPS"
    
    # Remove local archive
    rm -f "/tmp/$archive_name"
    
    log "${GREEN}Backup transfer completed${NC}"
}

# Clean up old backups on VPS
cleanup_old_backups() {
    log "${YELLOW}Cleaning up backups older than $RETENTION_DAYS days on VPS...${NC}"
    
    ssh -i "$SSH_KEY" -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_HOST" \
        "find '$REMOTE_BACKUP_DIR' -name 'nextcloud_backup_*.tar.gz' -type f -mtime +$RETENTION_DAYS -delete" || \
        log "${RED}WARNING: Failed to cleanup old backups${NC}"
    
    # List remaining backups
    local backup_count=$(ssh -i "$SSH_KEY" -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_HOST" \
        "find '$REMOTE_BACKUP_DIR' -name 'nextcloud_backup_*.tar.gz' -type f | wc -l")
    
    log "${GREEN}Cleanup completed. $backup_count backup(s) remaining on VPS${NC}"
}

# Main backup function
main() {
    log "${GREEN}=== NextCloud Backup Started ===${NC}"
    
    # Pre-flight checks
    check_requirements
    check_containers
    
    # Setup
    create_backup_dir
    
    # Backup process
    enable_maintenance_mode
    
    # Perform backups (order matters for consistency)
    backup_database
    backup_data
    backup_app_config
    create_backup_info
    
    # Always try to disable maintenance mode
    disable_maintenance_mode
    
    # Transfer and cleanup
    transfer_backup
    cleanup_old_backups
    
    # Local cleanup
    cleanup
    
    local end_time=$(date)
    log "${GREEN}=== NextCloud Backup Completed Successfully at $end_time ===${NC}"
    
    # Show backup size info
    local backup_size=$(ssh -i "$SSH_KEY" -p "$REMOTE_PORT" "$REMOTE_USER@$REMOTE_HOST" \
        "du -h '$REMOTE_BACKUP_DIR/nextcloud_backup_${BACKUP_DATE}.tar.gz' | cut -f1")
    log "${GREEN}Backup size: $backup_size${NC}"
}

# Trap to ensure maintenance mode is disabled on script exit
trap 'disable_maintenance_mode; cleanup; exit 1' ERR EXIT

# Run main function
main "$@"

# Remove trap on successful completion
trap - ERR EXIT