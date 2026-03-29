# Encore Helper Scripts

Collection of utility scripts for Encore development.

## Available Scripts

### `init-project.sh`
Initialize a new Encore project with language selection.

```bash
./scripts/init-project.sh [language] [app-name]
# Example:
./scripts/init-project.sh go my-api
./scripts/init-project.sh typescript my-backend
```

### `dev.sh`
Quick start the Encore development server with dashboard access.

```bash
./scripts/dev.sh
```

### `db-helper.sh`
Database management utilities.

```bash
./scripts/db-helper.sh reset          # Reset local database
./scripts/db-helper.sh shell          # Open database shell
./scripts/db-helper.sh migrate        # Run migrations
./scripts/db-helper.sh status         # Show database status
./scripts/db-helper.sh new-migration <service>  # Migration help
```

### `deploy.sh`
Deployment helpers for Encore Cloud and self-hosted options.

```bash
./scripts/deploy.sh <env> <command>

# Examples:
./scripts/deploy.sh prod deploy
./scripts/deploy.sh prod logs
./scripts/deploy.sh prod build-docker myapp:v1.0
./scripts/deploy.sh prod build-k8s ./k8s
```

### `gen-client.sh`
Generate API clients for frontend consumption.

```bash
./scripts/gen-client.sh [language] [output-dir]

# Examples:
./scripts/gen-client.sh typescript ./frontend/src/client
./scripts/gen-client.sh go ./clients/go
```

### `secrets.sh`
Manage Encore secrets across environments.

```bash
./scripts/secrets.sh set <env> <key> <value>
./scripts/secrets.sh list <env>

# Examples:
./scripts/secrets.sh set local STRIPE_KEY sk_test_...
./scripts/secrets.sh set prod DATABASE_URL postgres://...
```

## Usage

All scripts should be run from your Encore project root directory (where `encore.app` is located).

```bash
# Add to your project
cp -r /path/to/skillforge/backend/encore/scripts ./scripts

# Or use directly from skillforge
/path/to/skillforge/backend/encore/scripts/dev.sh
```
