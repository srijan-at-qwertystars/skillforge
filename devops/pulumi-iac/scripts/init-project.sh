#!/usr/bin/env bash
# init-project.sh — Initialize a new Pulumi project with chosen language and cloud provider.
#
# Usage:
#   ./init-project.sh <project-name> [--lang ts|py|go|csharp|yaml] [--cloud aws|azure|gcp|k8s]
#                     [--desc "description"] [--stack dev] [--dir ./path]
#
# Examples:
#   ./init-project.sh my-infra
#   ./init-project.sh my-infra --lang py --cloud azure
#   ./init-project.sh my-infra --lang go --cloud gcp --stack staging --dir ./infra

set -euo pipefail

# ---------- defaults ----------
LANG="ts"
CLOUD="aws"
DESC=""
STACK="dev"
DIR=""

# ---------- colors ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$@"; exit 1; }

# ---------- usage ----------
usage() {
    cat <<EOF
Usage: $(basename "$0") <project-name> [options]

Options:
  --lang   ts|py|go|csharp|yaml   Language (default: ts)
  --cloud  aws|azure|gcp|k8s      Cloud provider (default: aws)
  --desc   "description"           Project description
  --stack  name                    Initial stack name (default: dev)
  --dir    path                    Target directory (default: ./<project-name>)
  -h, --help                       Show this help
EOF
    exit 0
}

# ---------- parse args ----------
[[ $# -lt 1 ]] && usage

PROJECT_NAME="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lang)   LANG="$2";  shift 2 ;;
        --cloud)  CLOUD="$2"; shift 2 ;;
        --desc)   DESC="$2";  shift 2 ;;
        --stack)  STACK="$2"; shift 2 ;;
        --dir)    DIR="$2";   shift 2 ;;
        -h|--help) usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ---------- validate ----------
VALID_LANGS="ts py go csharp yaml"
VALID_CLOUDS="aws azure gcp k8s"

echo "$VALID_LANGS" | grep -qw "$LANG"  || die "Invalid language '$LANG'. Choose from: $VALID_LANGS"
echo "$VALID_CLOUDS" | grep -qw "$CLOUD" || die "Invalid cloud '$CLOUD'. Choose from: $VALID_CLOUDS"

command -v pulumi >/dev/null 2>&1 || die "pulumi CLI not found. Install: https://www.pulumi.com/docs/install/"

# ---------- map template name ----------
declare -A LANG_MAP=(
    [ts]="typescript"
    [py]="python"
    [go]="go"
    [csharp]="csharp"
    [yaml]="yaml"
)

declare -A CLOUD_MAP=(
    [aws]="aws"
    [azure]="azure"
    [gcp]="gcp"
    [k8s]="kubernetes"
)

TEMPLATE="${CLOUD_MAP[$CLOUD]}-${LANG_MAP[$LANG]}"

# ---------- create project ----------
TARGET_DIR="${DIR:-"./$PROJECT_NAME"}"

if [[ -d "$TARGET_DIR" ]]; then
    die "Directory '$TARGET_DIR' already exists."
fi

mkdir -p "$TARGET_DIR"
info "Initializing Pulumi project '${PROJECT_NAME}' with template '${TEMPLATE}' in '${TARGET_DIR}'"

PULUMI_ARGS=(
    new "$TEMPLATE"
    --name "$PROJECT_NAME"
    --stack "$STACK"
    --yes
    --dir "$TARGET_DIR"
)

[[ -n "$DESC" ]] && PULUMI_ARGS+=(--description "$DESC")

pulumi "${PULUMI_ARGS[@]}"

# ---------- post-init ----------
info "Installing dependencies..."
case "$LANG" in
    ts)
        (cd "$TARGET_DIR" && npm install)
        ;;
    py)
        (cd "$TARGET_DIR" && python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt)
        ;;
    go)
        (cd "$TARGET_DIR" && go mod tidy)
        ;;
    csharp)
        (cd "$TARGET_DIR" && dotnet restore)
        ;;
    yaml)
        info "No dependencies to install for YAML projects."
        ;;
esac

# ---------- git init ----------
if [[ ! -d "$TARGET_DIR/.git" ]]; then
    info "Initializing git repository..."
    (cd "$TARGET_DIR" && git init -q && git add -A && git commit -q -m "Initial Pulumi project: $TEMPLATE")
fi

# ---------- summary ----------
info "Project created successfully!"
echo ""
echo "  Project:   $PROJECT_NAME"
echo "  Template:  $TEMPLATE"
echo "  Stack:     $STACK"
echo "  Directory: $TARGET_DIR"
echo ""
echo "Next steps:"
echo "  cd $TARGET_DIR"
echo "  pulumi config set ${CLOUD_MAP[$CLOUD]}:region <region>"
echo "  pulumi up"
