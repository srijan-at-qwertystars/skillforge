# Crontab Templates

Copy-paste ready crontab entries for common tasks. Adjust paths and parameters to your environment.

---

## Header (Always Include)

```bash
# === Crontab for [hostname/service] ===
# Last updated: YYYY-MM-DD by [name]
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=ops@example.com
# MAILTO="" to disable email notifications
```

---

## Backups

```bash
# --- Database Backups ---

# PostgreSQL: daily full backup at 2 AM
0 2 * * * pg_dump -U postgres mydb | gzip > /backups/db/mydb-$(date +\%Y\%m\%d).sql.gz 2>> /var/log/cron-jobs/db-backup.log

# MySQL: daily backup at 2:30 AM
30 2 * * * mysqldump --single-transaction -u backup_user mydb | gzip > /backups/db/mydb-$(date +\%Y\%m\%d).sql.gz 2>> /var/log/cron-jobs/db-backup.log

# MongoDB: daily backup at 3 AM
0 3 * * * mongodump --db mydb --archive=/backups/db/mongo-$(date +\%Y\%m\%d).archive --gzip 2>> /var/log/cron-jobs/mongo-backup.log

# Redis: daily RDB snapshot at 3:30 AM
30 3 * * * redis-cli BGSAVE && sleep 30 && cp /var/lib/redis/dump.rdb /backups/redis/dump-$(date +\%Y\%m\%d).rdb

# --- File Backups ---

# Rsync to remote server: daily at 1 AM
0 1 * * * rsync -avz --delete /data/ backup@remote:/backups/data/ >> /var/log/cron-jobs/rsync.log 2>&1

# Tarball of config files: weekly Sunday 3 AM
0 3 * * 0 tar czf /backups/configs/etc-$(date +\%Y\%m\%d).tar.gz /etc/ 2>> /var/log/cron-jobs/config-backup.log

# S3 sync: every 6 hours
0 */6 * * * aws s3 sync /data/uploads s3://mybucket/uploads --delete >> /var/log/cron-jobs/s3-sync.log 2>&1
```

---

## Log Management

```bash
# --- Log Rotation & Cleanup ---

# Delete logs older than 30 days: daily at 4 AM
0 4 * * * find /var/log/app/ -name "*.log" -mtime +30 -delete 2>&1 | logger -t log-cleanup

# Compress logs older than 7 days: daily at 4:15 AM
15 4 * * * find /var/log/app/ -name "*.log" -mtime +7 ! -name "*.gz" -exec gzip {} \;

# Truncate large log files (keep last 10000 lines): daily at 4:30 AM
30 4 * * * for f in /var/log/app/*.log; do tail -10000 "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done

# Archive and compress weekly logs: Sunday at 5 AM
0 5 * * 0 cd /var/log/app && tar czf /backups/logs/app-logs-$(date +\%Y\%m\%d).tar.gz *.log.1 && rm -f *.log.1

# Delete old backup archives older than 90 days
0 5 * * * find /backups/ -name "*.tar.gz" -mtime +90 -delete
```

---

## System Maintenance

```bash
# --- Disk & Filesystem ---

# Check disk usage, alert if >80%
*/30 * * * * df -h | awk '$5+0 > 80 {print}' | mail -s "Disk Alert: $(hostname)" ops@example.com

# Clean Docker resources: weekly Sunday at 6 AM
0 6 * * 0 docker system prune -af --volumes >> /var/log/cron-jobs/docker-cleanup.log 2>&1

# Clean temp files older than 24 hours
0 */4 * * * find /tmp -type f -atime +1 -user appuser -delete 2>/dev/null

# Clean package manager cache: weekly
0 6 * * 0 apt-get clean && apt-get autoremove -y > /dev/null 2>&1

# --- Updates ---

# Security updates check (don't auto-install): daily
0 7 * * * apt-get update -qq && apt-get -s upgrade 2>/dev/null | grep -i securi | mail -s "Security Updates: $(hostname)" ops@example.com
```

---

## Health Checks

```bash
# --- Service Monitoring ---

# Check if web server is responding: every 2 minutes
*/2 * * * * curl -fsS -o /dev/null -w "\%{http_code}" http://localhost:8080/health || echo "Web server down" | mail -s "ALERT: $(hostname) web down" ops@example.com

# Restart service if not running: every 5 minutes
*/5 * * * * pgrep -x myapp > /dev/null || (systemctl restart myapp && echo "Restarted myapp at $(date)" >> /var/log/cron-jobs/auto-restart.log)

# Check SSL certificate expiry: daily at 8 AM
0 8 * * * echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | openssl x509 -noout -enddate | grep -q "$(date -d '+30 days' +notAfter=\%b)" && echo "SSL cert expires within 30 days" | mail -s "SSL Alert" ops@example.com

# Database connectivity check: every 10 minutes
*/10 * * * * pg_isready -h localhost -U postgres > /dev/null 2>&1 || echo "PostgreSQL DOWN" | mail -s "DB ALERT: $(hostname)" ops@example.com

# Ping healthchecks.io: every 5 minutes (dead man's switch)
*/5 * * * * curl -fsS --retry 3 https://hc-ping.com/YOUR-UUID > /dev/null 2>&1
```

---

## Reports

```bash
# --- Scheduled Reports ---

# Daily summary report at 7 AM on weekdays
0 7 * * 1-5 /usr/local/bin/daily-report.sh | mail -s "Daily Report $(date +\%Y-\%m-\%d)" team@example.com

# Weekly metrics digest: Monday at 9 AM
0 9 * * 1 /usr/local/bin/weekly-metrics.sh | mail -s "Weekly Metrics" management@example.com

# Monthly billing report: 1st of month at 8 AM
0 8 1 * * /usr/local/bin/billing-report.sh >> /var/log/cron-jobs/billing.log 2>&1

# Quarterly compliance audit: first day of Jan, Apr, Jul, Oct
0 6 1 1,4,7,10 * /usr/local/bin/compliance-audit.sh >> /var/log/cron-jobs/compliance.log 2>&1
```

---

## Application Tasks

```bash
# --- Cache & Sessions ---

# Clear expired sessions: every 30 minutes
*/30 * * * * /usr/local/bin/php /var/www/app/artisan session:gc > /dev/null 2>&1

# Warm cache after deployment: (run manually or from deploy script)
# @reboot sleep 30 && /usr/local/bin/warm-cache.sh >> /var/log/cron-jobs/cache-warm.log 2>&1

# --- Queue Processing ---

# Process job queue: every minute
* * * * * /usr/local/bin/php /var/www/app/artisan queue:work --stop-when-empty > /dev/null 2>&1

# Send queued emails: every 5 minutes
*/5 * * * * /usr/local/bin/php /var/www/app/artisan queue:work --queue=emails --max-jobs=50 > /dev/null 2>&1

# --- Data Processing ---

# ETL pipeline: daily at 1 AM
0 1 * * * /usr/bin/flock -n /tmp/etl.lock /usr/local/bin/python3 /app/etl/pipeline.py >> /var/log/cron-jobs/etl.log 2>&1

# Sync external API data: every 15 minutes during business hours
*/15 8-18 * * 1-5 /usr/local/bin/python3 /app/scripts/api-sync.py >> /var/log/cron-jobs/api-sync.log 2>&1

# Generate sitemap: daily at 5 AM
0 5 * * * /usr/local/bin/python3 /app/scripts/gen-sitemap.py > /var/www/html/sitemap.xml 2>> /var/log/cron-jobs/sitemap.log
```

---

## Security

```bash
# --- Security Scans ---

# Check for rootkits: weekly Sunday at 2 AM
0 2 * * 0 /usr/bin/rkhunter --check --skip-keypress --report-warnings-only 2>&1 | mail -s "rkhunter: $(hostname)" security@example.com

# Scan for file changes (AIDE): daily at 3 AM
0 3 * * * /usr/bin/aide --check 2>&1 | mail -s "AIDE Report: $(hostname)" security@example.com

# Audit failed login attempts: daily at 7 AM
0 7 * * * grep "Failed password" /var/log/auth.log | tail -50 | mail -s "Failed Logins: $(hostname)" security@example.com

# Rotate application secrets/tokens: monthly
0 4 1 * * /usr/local/bin/rotate-secrets.sh >> /var/log/cron-jobs/secret-rotation.log 2>&1
```

---

## Template With Wrapper

Using `cron-wrapper.sh` from this skill's scripts:

```bash
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""

# All jobs use wrapper for consistent logging, locking, and monitoring
WRAPPER=/usr/local/bin/cron-wrapper.sh

0 2 * * * $WRAPPER -n db-backup --healthcheck-url https://hc-ping.com/UUID1 -- /app/backup.sh
*/5 * * * * $WRAPPER -n health-check --timeout 30 --no-lock -- /app/check.sh
0 1 * * * $WRAPPER -n etl-pipeline --timeout 3600 -- /app/etl/run.sh
0 4 * * * $WRAPPER -n log-cleanup --no-lock -- find /var/log/app -mtime +30 -delete
```
