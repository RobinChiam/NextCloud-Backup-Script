# Backup Script Installation

## On Nextcloud VM
1. `mkdir /opt/scripts`
2. `sudo nano /opt/scripts/nextcloud_backup.sh`
3. `chmod +x /opt/scripts/nextcloud_backup.sh`
4. `sudo touch /var/log/nextcloud_backup.log`
5. `sudo chmod 644 /var/log/nextcloud_backup.log`
### SSH Connection Test - Replace the [ ] with your own values
`ssh -i [SSH KEY] -p [PORT] user@[SERVER_IP] "echo 'SSH Success!'"`

### Setup Cron
1. `sudo crontab -e`
2. `0 2 * * * /opt/scripts/nextcloud_backup.sh >> /var/log/nextcloud_backup.log 2>&1`
	 `# Add this line to run backup every night at 2:00 AM`

### Setup Log Rotation
1. `sudo nano /etc/logrotate.d/nextcloud-backup`
2. Create the LogRotate Configuration
```bash
# Add this content:
/var/log/nextcloud_backup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
}
```
### Manual Backup
`sudo /opt/scripts/nextcloud_backup.sh`

### Verify Database Backup
1. Check the backup from the VPS
   `ssh -i [SSH KEY] -p [PORT] user@[SERVER_IP] "ls -lah /home/user/backup/nextcloud/"`
2. Download and test the backup
   `ssh -i [SSH KEY] -p [PORT] user@[SERVER_IP] "cd /home/user/backup/nextcloud && tar -xzf nextcloud_backup_*.tar.gz && ls -la nextcloud_backup_*/"`


# Backup Restoration

1. Take down Docker Containers
   `docker-compose down`
2. Extract the backup from VPS
```bash
# Extract the remote archive
ssh -i ${SSH_KEY} -p ${REMOTE_PORT} ${REMOTE_USER}@${REMOTE_HOST} "cd ${REMOTE_BACKUP_DIR} && tar -xzf nextcloud_backup_TIMESTAMP.tar.gz"

# Download the extracted folder to your local restore directory
scp -i ${SSH_KEY} -P ${REMOTE_PORT} -r ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BACKUP_DIR}/nextcloud_backup_TIMESTAMP/ ./restore/
```
3. Restore the database
```bash
docker-compose up -d db

# Wait for the database to initialize
sleep 10

# Use the password variable from your environment
gunzip < restore/database.sql.gz | docker exec -i nextcloud_db mysql -u nextcloud -p"${DB_PASS}" nextcloud-db
```
4. Restore **Nextcloud Data**
```bash
sudo rm -rf /mnt/nextcloud-data/*
sudo tar -xzf restore/nextcloud_data.tar.gz -C /mnt/
```
5. Restore Application Files
```bash
docker volume rm nextcloud
docker volume create nextcloud
docker run --rm -v nextcloud:/target -v $(pwd)/restore:/source alpine tar -xzf /source/nextcloud_app.tar.gz -C /target
```
6. Start the containers
```bash
docker-compose up -d
```
7. Disable Maintenance Mode
   `docker exec -u www-data nextcloud_app php occ maintenance:mode --off`
