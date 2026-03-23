#!/usr/bin/env bash
# mise-project-init.sh — Initialize .mise.toml for a project
# Usage: ./mise-project-init.sh [project-dir]
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✔${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✖${NC} $*" >&2; }
header(){ echo -e "${CYAN}▸${NC} $*"; }

PROJECT_DIR="${1:-.}"

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  echo "Usage: $(basename "$0") [project-dir]"
  echo ""
  echo "Initialize a .mise.toml for a project by detecting languages and suggesting tools."
  echo "If no directory is given, uses the current directory."
  exit 0
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
  err "Directory not found: $PROJECT_DIR"
  exit 1
fi

cd "$PROJECT_DIR"
PROJECT_DIR=$(pwd)
OUTPUT_FILE="$PROJECT_DIR/.mise.toml"

if [[ -f "$OUTPUT_FILE" ]]; then
  warn ".mise.toml already exists at $OUTPUT_FILE"
  read -rp "Overwrite? [y/N] " answer
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    info "Aborted."
    exit 0
  fi
fi

info "Scanning project: $PROJECT_DIR"
echo ""

# --- Detect languages/frameworks ---
declare -A DETECTED_TOOLS  # tool -> suggested_version
declare -a DETECTED_TASKS  # task definitions
declare -a ENV_VARS        # environment variables

detect_node() {
  if [[ -f "package.json" || -f ".nvmrc" || -f ".node-version" ]]; then
    local version="lts"
    if [[ -f ".nvmrc" ]]; then
      version=$(cat .nvmrc | tr -d 'v' | xargs)
    elif [[ -f ".node-version" ]]; then
      version=$(cat .node-version | tr -d 'v' | xargs)
    fi
    DETECTED_TOOLS[node]="$version"
    header "Detected Node.js (version: $version)"

    # Detect package manager
    if [[ -f "pnpm-lock.yaml" ]]; then
      header "  └─ pnpm detected"
      DETECTED_TASKS+=('[tasks.install]\ndescription = "Install dependencies"\nrun = "pnpm install"')
      DETECTED_TASKS+=('[tasks.dev]\ndescription = "Start dev server"\nrun = "pnpm dev"')
      DETECTED_TASKS+=('[tasks.build]\ndescription = "Build project"\nrun = "pnpm build"')
      DETECTED_TASKS+=('[tasks.test]\ndescription = "Run tests"\nrun = "pnpm test"')
    elif [[ -f "yarn.lock" ]]; then
      header "  └─ yarn detected"
      DETECTED_TASKS+=('[tasks.install]\ndescription = "Install dependencies"\nrun = "yarn install"')
      DETECTED_TASKS+=('[tasks.dev]\ndescription = "Start dev server"\nrun = "yarn dev"')
      DETECTED_TASKS+=('[tasks.build]\ndescription = "Build project"\nrun = "yarn build"')
      DETECTED_TASKS+=('[tasks.test]\ndescription = "Run tests"\nrun = "yarn test"')
    elif [[ -f "package-lock.json" || -f "package.json" ]]; then
      DETECTED_TASKS+=('[tasks.install]\ndescription = "Install dependencies"\nrun = "npm install"')
      DETECTED_TASKS+=('[tasks.dev]\ndescription = "Start dev server"\nrun = "npm run dev"')
      DETECTED_TASKS+=('[tasks.build]\ndescription = "Build project"\nrun = "npm run build"')
      DETECTED_TASKS+=('[tasks.test]\ndescription = "Run tests"\nrun = "npm test"')
    fi
    ENV_VARS+=('NODE_ENV = "development"')
  fi
}

detect_python() {
  if [[ -f "requirements.txt" || -f "setup.py" || -f "setup.cfg" || \
        -f "pyproject.toml" || -f "Pipfile" || -f ".python-version" ]]; then
    local version="3.12"
    if [[ -f ".python-version" ]]; then
      version=$(cat .python-version | xargs)
    fi
    DETECTED_TOOLS[python]="$version"
    header "Detected Python (version: $version)"

    if [[ -f "pyproject.toml" ]] && grep -q "poetry" pyproject.toml 2>/dev/null; then
      header "  └─ Poetry detected"
      DETECTED_TASKS+=('[tasks.install]\ndescription = "Install dependencies"\nrun = "poetry install"')
      DETECTED_TASKS+=('[tasks.test]\ndescription = "Run tests"\nrun = "poetry run pytest"')
    elif [[ -f "requirements.txt" ]]; then
      DETECTED_TASKS+=('[tasks.install]\ndescription = "Install dependencies"\nrun = "pip install -r requirements.txt"')
      DETECTED_TASKS+=('[tasks.test]\ndescription = "Run tests"\nrun = "pytest"')
    fi
  fi
}

detect_ruby() {
  if [[ -f "Gemfile" || -f ".ruby-version" ]]; then
    local version="3.3"
    if [[ -f ".ruby-version" ]]; then
      version=$(cat .ruby-version | xargs)
    fi
    DETECTED_TOOLS[ruby]="$version"
    header "Detected Ruby (version: $version)"

    if [[ -f "Gemfile" ]]; then
      DETECTED_TASKS+=('[tasks.install]\ndescription = "Install dependencies"\nrun = "bundle install"')
    fi
    if [[ -f "Rakefile" ]]; then
      DETECTED_TASKS+=('[tasks.test]\ndescription = "Run tests"\nrun = "bundle exec rake test"')
    fi
  fi
}

detect_go() {
  if [[ -f "go.mod" || -f ".go-version" ]]; then
    local version="latest"
    if [[ -f ".go-version" ]]; then
      version=$(cat .go-version | xargs)
    elif [[ -f "go.mod" ]]; then
      local mod_version
      mod_version=$(grep '^go ' go.mod 2>/dev/null | awk '{print $2}' || true)
      [[ -n "$mod_version" ]] && version="$mod_version"
    fi
    DETECTED_TOOLS[go]="$version"
    header "Detected Go (version: $version)"
    DETECTED_TASKS+=('[tasks.build]\ndescription = "Build project"\nrun = "go build ./..."')
    DETECTED_TASKS+=('[tasks.test]\ndescription = "Run tests"\nrun = "go test ./..."')
    DETECTED_TASKS+=('[tasks.lint]\ndescription = "Lint code"\nrun = "golangci-lint run"')
  fi
}

detect_rust() {
  if [[ -f "Cargo.toml" ]]; then
    DETECTED_TOOLS[rust]="stable"
    header "Detected Rust (stable)"
    DETECTED_TASKS+=('[tasks.build]\ndescription = "Build project"\nrun = "cargo build"')
    DETECTED_TASKS+=('[tasks.test]\ndescription = "Run tests"\nrun = "cargo test"')
    DETECTED_TASKS+=('[tasks.lint]\ndescription = "Lint code"\nrun = "cargo clippy"')
    DETECTED_TASKS+=('[tasks.fmt]\ndescription = "Format code"\nrun = "cargo fmt"')
  fi
}

detect_java() {
  if [[ -f "pom.xml" || -f "build.gradle" || -f "build.gradle.kts" || -f ".java-version" ]]; then
    local version="21"
    if [[ -f ".java-version" ]]; then
      version=$(cat .java-version | xargs)
    fi
    DETECTED_TOOLS[java]="$version"
    header "Detected Java (version: $version)"

    if [[ -f "pom.xml" ]]; then
      DETECTED_TASKS+=('[tasks.build]\ndescription = "Build project"\nrun = "mvn package"')
      DETECTED_TASKS+=('[tasks.test]\ndescription = "Run tests"\nrun = "mvn test"')
    elif [[ -f "build.gradle" || -f "build.gradle.kts" ]]; then
      DETECTED_TASKS+=('[tasks.build]\ndescription = "Build project"\nrun = "./gradlew build"')
      DETECTED_TASKS+=('[tasks.test]\ndescription = "Run tests"\nrun = "./gradlew test"')
    fi
  fi
}

detect_terraform() {
  if ls *.tf &>/dev/null 2>&1; then
    DETECTED_TOOLS[terraform]="1.7"
    header "Detected Terraform"
    DETECTED_TASKS+=('[tasks.init]\ndescription = "Initialize Terraform"\nrun = "terraform init"')
    DETECTED_TASKS+=('[tasks.plan]\ndescription = "Terraform plan"\nrun = "terraform plan"')
    DETECTED_TASKS+=('[tasks.apply]\ndescription = "Terraform apply"\nrun = "terraform apply"')
  fi
}

detect_elixir() {
  if [[ -f "mix.exs" ]]; then
    DETECTED_TOOLS[erlang]="26"
    DETECTED_TOOLS[elixir]="1.16"
    header "Detected Elixir + Erlang"
    DETECTED_TASKS+=('[tasks.deps]\ndescription = "Fetch dependencies"\nrun = "mix deps.get"')
    DETECTED_TASKS+=('[tasks.test]\ndescription = "Run tests"\nrun = "mix test"')
  fi
}

# Run all detections
detect_node
detect_python
detect_ruby
detect_go
detect_rust
detect_java
detect_terraform
detect_elixir

if [[ ${#DETECTED_TOOLS[@]} -eq 0 ]]; then
  warn "No languages/frameworks detected."
  info "Creating a minimal .mise.toml template."
fi

# --- Generate .mise.toml ---
echo ""
info "Generating $OUTPUT_FILE..."

{
  echo "# .mise.toml — generated by mise-project-init"
  echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo 'min_version = "2025.1.0"'
  echo ""

  # Tools section
  if [[ ${#DETECTED_TOOLS[@]} -gt 0 ]]; then
    echo "[tools]"
    for tool in $(echo "${!DETECTED_TOOLS[@]}" | tr ' ' '\n' | sort); do
      echo "$tool = \"${DETECTED_TOOLS[$tool]}\""
    done
    echo ""
  fi

  # Environment section
  if [[ ${#ENV_VARS[@]} -gt 0 ]]; then
    echo "[env]"
    for var in "${ENV_VARS[@]}"; do
      echo "$var"
    done
    echo ""
  fi

  # Tasks section — deduplicate by task name, keep first
  if [[ ${#DETECTED_TASKS[@]} -gt 0 ]]; then
    declare -A seen_tasks
    for task_block in "${DETECTED_TASKS[@]}"; do
      task_name=$(echo -e "$task_block" | head -1 | sed 's/\[tasks\.\(.*\)\]/\1/')
      if [[ -z "${seen_tasks[$task_name]+x}" ]]; then
        seen_tasks[$task_name]=1
        echo -e "$task_block"
        echo ""
      fi
    done
  fi

  # Settings section
  echo "[settings]"
  echo "legacy_version_file = true"

} > "$OUTPUT_FILE"

ok "Created $OUTPUT_FILE"
echo ""
echo "--- Generated .mise.toml ---"
cat "$OUTPUT_FILE"
echo "---"
echo ""

# --- Next steps ---
info "Next steps:"
echo "  1. Review and adjust versions in $OUTPUT_FILE"
echo "  2. Run 'mise install' to install all tools"
echo "  3. Add project-specific env vars to [env]"
echo "  4. Customize tasks in [tasks]"
echo "  5. Commit .mise.toml to version control"
echo "  6. Add '.mise.local.toml' to .gitignore"
