# PocketBase Scripts

Helper scripts for managing PocketBase instances.

## Available Scripts

### install.sh
Download and install the latest (or specific version) PocketBase binary.

```bash
./scripts/install.sh [version] [os] [arch] [install_dir]

# Examples:
./scripts/install.sh                          # Latest, linux/amd64, /usr/local/bin
./scripts/install.sh latest linux amd64 ./    # Latest to current directory
./scripts/install.sh 0.22.0 darwin arm64      # Specific version for Mac M1
```

### backup.sh
Create timestamped backups of the PocketBase SQLite database.

```bash
./scripts/backup.sh [data_dir] [backup_dir] [retention_days]

# Examples:
./scripts/backup.sh                           # Default: ./pb_data, ./backups, 7 days
./scripts/backup.sh ./pb_data ./backups 30   # Custom retention
```

### docker-setup.sh
Create a complete Docker Compose setup for PocketBase.

```bash
./scripts/docker-setup.sh [project_name] [http_port] [https_port]

# Examples:
./scripts/docker-setup.sh                     # Default: pocketbase-app, ports 8090/8091
./scripts/docker-setup.sh myapp 8080 8443     # Custom name and ports
```

Creates:
- `docker-compose.yml` - PocketBase service configuration
- `.env` - Environment variables
- `litestream.yml` - Backup configuration template
- `pb_data/`, `pb_public/`, `pb_hooks/`, `pb_migrations/` - Data directories

### migration.sh
Create a new database migration file with proper naming.

```bash
./scripts/migration.sh [migration_name] [pb_dir]

# Examples:
./scripts/migration.sh add_users_collection    # Creates: pb_migrations/20240101120000_add_users_collection.go
./scripts/migration.sh create_posts ./myapp    # Creates in custom directory
```

### health-check.sh
Check if a PocketBase instance is running and healthy.

```bash
./scripts/health-check.sh [url] [timeout]

# Examples:
./scripts/health-check.sh                      # Default: http://localhost:8090, 5s timeout
./scripts/health-check.sh http://pb.example.com 10
```

## Usage Tips

1. **Add to PATH**: Add the scripts directory to your PATH for easy access
2. **Cron backups**: Set up automated backups with cron:
   ```bash
   0 2 * * * /path/to/pocketbase/scripts/backup.sh /var/pb_data /var/backups 14
   ```
3. **CI/CD**: Use `health-check.sh` in deployment pipelines
