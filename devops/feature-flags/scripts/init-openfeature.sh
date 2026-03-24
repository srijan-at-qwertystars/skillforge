#!/usr/bin/env bash
#
# init-openfeature.sh — Bootstrap OpenFeature in an existing project.
#
# Detects the project language (or accepts an override), installs the
# OpenFeature SDK and a feature-flag provider, generates a configuration
# file, and writes a ready-to-run usage example.
#
# Usage:
#   init-openfeature.sh [OPTIONS]
#
# Options:
#   --lang <node|python|go|java>           Override automatic language detection
#   --provider <flagd|launchdarkly|unleash|flagsmith>
#                                          Provider to install (default: flagd)
#   --dir <path>                           Target directory (default: .)
#   --dry-run                              Show what would be done without doing it
#   --help                                 Show this help message
#
# Examples:
#   # Auto-detect language, use flagd provider
#   init-openfeature.sh
#
#   # Force Node.js with LaunchDarkly provider
#   init-openfeature.sh --lang node --provider launchdarkly
#
#   # Dry-run in a specific directory
#   init-openfeature.sh --dir /path/to/project --dry-run
#
#   # Go project with unleash provider
#   init-openfeature.sh --lang go --provider unleash

set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
LANG_OVERRIDE=""
PROVIDER="flagd"
TARGET_DIR="."
DRY_RUN=false
DETECTED_LANG=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf "\033[1;34m[INFO]\033[0m  %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m  %s\n" "$*" >&2; }
error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }
die()   { error "$@"; exit 1; }

run() {
  if $DRY_RUN; then
    info "(dry-run) $*"
  else
    info "Running: $*"
    eval "$@"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  if $DRY_RUN; then
    info "(dry-run) Would create $path"
    printf '%s\n' "$content"
  else
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    info "Created $path"
  fi
}

# ---------------------------------------------------------------------------
# Usage / Help
# ---------------------------------------------------------------------------
show_help() {
  sed -n '2,/^$/{ s/^# \{0,1\}//; p }' "$0"
  exit 0
}

# ---------------------------------------------------------------------------
# Argument Parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang)
        [[ -z "${2:-}" ]] && die "--lang requires an argument (node|python|go|java)"
        LANG_OVERRIDE="$2"; shift 2 ;;
      --provider)
        [[ -z "${2:-}" ]] && die "--provider requires an argument"
        PROVIDER="$2"; shift 2 ;;
      --dir)
        [[ -z "${2:-}" ]] && die "--dir requires a path argument"
        TARGET_DIR="$2"; shift 2 ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      --help|-h)
        show_help ;;
      *)
        die "Unknown option: $1 (use --help for usage)" ;;
    esac
  done

  # Validate --lang value
  if [[ -n "$LANG_OVERRIDE" ]]; then
    case "$LANG_OVERRIDE" in
      node|python|go|java) ;;
      *) die "Unsupported language: $LANG_OVERRIDE (choose node|python|go|java)" ;;
    esac
  fi

  # Validate --provider value
  case "$PROVIDER" in
    flagd|launchdarkly|unleash|flagsmith) ;;
    *) die "Unsupported provider: $PROVIDER (choose flagd|launchdarkly|unleash|flagsmith)" ;;
  esac

  # Validate target directory
  if [[ ! -d "$TARGET_DIR" ]]; then
    die "Target directory does not exist: $TARGET_DIR"
  fi
}

# ---------------------------------------------------------------------------
# Language Detection
# ---------------------------------------------------------------------------
detect_language() {
  if [[ -n "$LANG_OVERRIDE" ]]; then
    DETECTED_LANG="$LANG_OVERRIDE"
    info "Language override: $DETECTED_LANG"
    return
  fi

  local dir="$TARGET_DIR"

  if [[ -f "$dir/package.json" ]]; then
    DETECTED_LANG="node"
  elif [[ -f "$dir/requirements.txt" || -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]]; then
    DETECTED_LANG="python"
  elif [[ -f "$dir/go.mod" ]]; then
    DETECTED_LANG="go"
  elif [[ -f "$dir/pom.xml" || -f "$dir/build.gradle" ]]; then
    DETECTED_LANG="java"
  else
    die "Could not detect project language in $dir. Use --lang to specify manually."
  fi

  info "Detected language: $DETECTED_LANG"
}

# ---------------------------------------------------------------------------
# Provider Package Names
# ---------------------------------------------------------------------------
get_node_provider_pkg() {
  case "$PROVIDER" in
    flagd)         echo "@openfeature/flagd-provider" ;;
    launchdarkly)  echo "launchdarkly-js-server-sdk @openfeature/open-feature-launchdarkly-provider" ;;
    unleash)       echo "@openfeature/unleash-provider" ;;
    flagsmith)     echo "@openfeature/flagsmith-provider" ;;
  esac
}

get_python_provider_pkg() {
  case "$PROVIDER" in
    flagd)         echo "openfeature-provider-flagd" ;;
    launchdarkly)  echo "openfeature-provider-launchdarkly" ;;
    unleash)       echo "openfeature-provider-unleash" ;;
    flagsmith)     echo "openfeature-provider-flagsmith" ;;
  esac
}

get_go_provider_pkg() {
  case "$PROVIDER" in
    flagd)         echo "github.com/open-feature/go-sdk-contrib/providers/flagd" ;;
    launchdarkly)  echo "github.com/open-feature/go-sdk-contrib/providers/launchdarkly" ;;
    unleash)       echo "github.com/open-feature/go-sdk-contrib/providers/unleash" ;;
    flagsmith)     echo "github.com/open-feature/go-sdk-contrib/providers/flagsmith" ;;
  esac
}

# ---------------------------------------------------------------------------
# Install SDK + Provider
# ---------------------------------------------------------------------------
install_sdk() {
  info "Installing OpenFeature SDK and $PROVIDER provider for $DETECTED_LANG …"

  case "$DETECTED_LANG" in
    node)
      local provider_pkg
      provider_pkg="$(get_node_provider_pkg)"
      run "cd '$TARGET_DIR' && npm install @openfeature/server-sdk $provider_pkg"
      ;;
    python)
      local provider_pkg
      provider_pkg="$(get_python_provider_pkg)"
      run "cd '$TARGET_DIR' && pip install openfeature-sdk $provider_pkg"
      ;;
    go)
      local provider_pkg
      provider_pkg="$(get_go_provider_pkg)"
      run "cd '$TARGET_DIR' && go get github.com/open-feature/go-sdk && go get $provider_pkg"
      ;;
    java)
      install_java_sdk
      ;;
  esac
}

install_java_sdk() {
  local dir="$TARGET_DIR"

  if [[ -f "$dir/pom.xml" ]]; then
    info "Add the following dependency to your pom.xml:"
    cat <<'MAVEN'

  <!-- OpenFeature SDK -->
  <dependency>
    <groupId>dev.openfeature</groupId>
    <artifactId>sdk</artifactId>
    <version>1.7.0</version>
  </dependency>

MAVEN
    case "$PROVIDER" in
      flagd)
        cat <<'MAVEN'
  <!-- Flagd Provider -->
  <dependency>
    <groupId>dev.openfeature.contrib.providers</groupId>
    <artifactId>flagd</artifactId>
    <version>0.7.0</version>
  </dependency>
MAVEN
        ;;
      launchdarkly)
        cat <<'MAVEN'
  <!-- LaunchDarkly Provider -->
  <dependency>
    <groupId>dev.openfeature.contrib.providers</groupId>
    <artifactId>launchdarkly</artifactId>
    <version>0.3.0</version>
  </dependency>
MAVEN
        ;;
      unleash)
        cat <<'MAVEN'
  <!-- Unleash Provider -->
  <dependency>
    <groupId>dev.openfeature.contrib.providers</groupId>
    <artifactId>unleash</artifactId>
    <version>0.1.0</version>
  </dependency>
MAVEN
        ;;
      flagsmith)
        cat <<'MAVEN'
  <!-- Flagsmith Provider -->
  <dependency>
    <groupId>dev.openfeature.contrib.providers</groupId>
    <artifactId>flagsmith</artifactId>
    <version>0.1.0</version>
  </dependency>
MAVEN
        ;;
    esac

  elif [[ -f "$dir/build.gradle" ]]; then
    info "Add the following to your build.gradle dependencies:"
    echo ""
    echo "  implementation 'dev.openfeature:sdk:1.7.0'"
    case "$PROVIDER" in
      flagd)        echo "  implementation 'dev.openfeature.contrib.providers:flagd:0.7.0'" ;;
      launchdarkly) echo "  implementation 'dev.openfeature.contrib.providers:launchdarkly:0.3.0'" ;;
      unleash)      echo "  implementation 'dev.openfeature.contrib.providers:unleash:0.1.0'" ;;
      flagsmith)    echo "  implementation 'dev.openfeature.contrib.providers:flagsmith:0.1.0'" ;;
    esac
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Create Config File
# ---------------------------------------------------------------------------
create_config() {
  info "Creating configuration file …"

  case "$DETECTED_LANG" in
    node)   create_config_node ;;
    python) create_config_python ;;
    go)     create_config_go ;;
    java)   create_config_java ;;
  esac
}

create_config_node() {
  local content
  read -r -d '' content <<'EOF' || true
{
  "openfeature": {
    "provider": "PROVIDER_PLACEHOLDER",
    "providerConfig": {
      "host": "localhost",
      "port": 8013,
      "tls": false
    },
    "defaults": {
      "booleanFlags": {},
      "stringFlags": {},
      "numberFlags": {},
      "objectFlags": {}
    }
  }
}
EOF
  content="${content//PROVIDER_PLACEHOLDER/$PROVIDER}"
  write_file "$TARGET_DIR/openfeature.config.json" "$content"
}

create_config_python() {
  local content
  read -r -d '' content <<EOF || true
# OpenFeature Configuration
OPENFEATURE_PROVIDER = "$PROVIDER"

OPENFEATURE_CONFIG = {
    "provider": "$PROVIDER",
    "host": "localhost",
    "port": 8013,
    "tls": False,
}
EOF
  write_file "$TARGET_DIR/openfeature_config.py" "$content"
}

create_config_go() {
  local content
  read -r -d '' content <<EOF || true
package config

// OpenFeatureConfig holds the feature flag provider configuration.
type OpenFeatureConfig struct {
	Provider string
	Host     string
	Port     int
	TLS      bool
}

// DefaultConfig returns sensible defaults for local development.
func DefaultConfig() OpenFeatureConfig {
	return OpenFeatureConfig{
		Provider: "$PROVIDER",
		Host:     "localhost",
		Port:     8013,
		TLS:      false,
	}
}
EOF
  write_file "$TARGET_DIR/openfeature_config.go" "$content"
}

create_config_java() {
  local content
  read -r -d '' content <<EOF || true
package com.example.config;

/**
 * OpenFeature configuration constants.
 */
public class OpenFeatureConfig {
    public static final String PROVIDER = "$PROVIDER";
    public static final String HOST = "localhost";
    public static final int PORT = 8013;
    public static final boolean TLS = false;
}
EOF
  write_file "$TARGET_DIR/OpenFeatureConfig.java" "$content"
}

# ---------------------------------------------------------------------------
# Generate Usage Example
# ---------------------------------------------------------------------------
generate_example() {
  info "Generating usage example …"

  case "$DETECTED_LANG" in
    node)   generate_example_node ;;
    python) generate_example_python ;;
    go)     generate_example_go ;;
    java)   generate_example_java ;;
  esac
}

generate_example_node() {
  local provider_import provider_init
  case "$PROVIDER" in
    flagd)
      provider_import="const { FlagdProvider } = require('@openfeature/flagd-provider');"
      provider_init="new FlagdProvider({ host: 'localhost', port: 8013 })" ;;
    launchdarkly)
      provider_import="const { LaunchDarklyProvider } = require('@openfeature/open-feature-launchdarkly-provider');"
      provider_init="new LaunchDarklyProvider('YOUR_SDK_KEY')" ;;
    unleash)
      provider_import="const { UnleashProvider } = require('@openfeature/unleash-provider');"
      provider_init="new UnleashProvider({ url: 'http://localhost:4242/api', appName: 'my-app' })" ;;
    flagsmith)
      provider_import="const { FlagsmithProvider } = require('@openfeature/flagsmith-provider');"
      provider_init="new FlagsmithProvider({ environmentKey: 'YOUR_ENV_KEY' })" ;;
  esac

  local content
  read -r -d '' content <<EOF || true
/**
 * OpenFeature Usage Example
 *
 * Demonstrates provider initialization, client creation,
 * flag evaluation with context, and hook registration.
 */
const { OpenFeature } = require('@openfeature/server-sdk');
${provider_import}

// --- Custom logging hook ---------------------------------------------------
const loggingHook = {
  before: (hookContext) => {
    console.log(\`[Hook] Evaluating flag: \${hookContext.flagKey}\`);
  },
  after: (hookContext, evaluationDetails) => {
    console.log(\`[Hook] Flag \${hookContext.flagKey} = \${evaluationDetails.value}\`);
  },
  error: (hookContext, err) => {
    console.error(\`[Hook] Error evaluating \${hookContext.flagKey}:\`, err);
  },
  finally: (hookContext) => {
    console.log(\`[Hook] Done evaluating \${hookContext.flagKey}\`);
  },
};

async function main() {
  // 1. Register the provider
  await OpenFeature.setProviderAndWait(${provider_init});

  // 2. Register hooks globally
  OpenFeature.addHooks(loggingHook);

  // 3. Create a client
  const client = OpenFeature.getClient('my-app');

  // 4. Build evaluation context
  const context = {
    targetingKey: 'user-123',
    email: 'user@example.com',
    plan: 'premium',
  };

  // 5. Evaluate feature flags
  const showBanner = await client.getBooleanValue('show-welcome-banner', false, context);
  console.log('show-welcome-banner:', showBanner);

  const headerColor = await client.getStringValue('header-color', 'blue', context);
  console.log('header-color:', headerColor);

  const maxItems = await client.getNumberValue('max-items', 10, context);
  console.log('max-items:', maxItems);

  // 6. Clean up
  await OpenFeature.close();
}

main().catch(console.error);
EOF
  write_file "$TARGET_DIR/openfeature_example.js" "$content"
}

generate_example_python() {
  local provider_import provider_init
  case "$PROVIDER" in
    flagd)
      provider_import="from openfeature.contrib.provider.flagd import FlagdProvider"
      provider_init="FlagdProvider(host=\"localhost\", port=8013)" ;;
    launchdarkly)
      provider_import="from openfeature.contrib.provider.launchdarkly import LaunchDarklyProvider"
      provider_init="LaunchDarklyProvider(sdk_key=\"YOUR_SDK_KEY\")" ;;
    unleash)
      provider_import="from openfeature.contrib.provider.unleash import UnleashProvider"
      provider_init="UnleashProvider(url=\"http://localhost:4242/api\", app_name=\"my-app\")" ;;
    flagsmith)
      provider_import="from openfeature.contrib.provider.flagsmith import FlagsmithProvider"
      provider_init="FlagsmithProvider(environment_key=\"YOUR_ENV_KEY\")" ;;
  esac

  local content
  read -r -d '' content <<EOF || true
"""
OpenFeature Usage Example

Demonstrates provider initialization, client creation,
flag evaluation with context, and hook registration.
"""

from openfeature import api
from openfeature.evaluation_context import EvaluationContext
from openfeature.hook import Hook
${provider_import}


# --- Custom logging hook ----------------------------------------------------
class LoggingHook(Hook):
    def before(self, hook_context, hints=None):
        print(f"[Hook] Evaluating flag: {hook_context.flag_key}")

    def after(self, hook_context, details, hints=None):
        print(f"[Hook] Flag {hook_context.flag_key} = {details.value}")

    def error(self, hook_context, exception, hints=None):
        print(f"[Hook] Error evaluating {hook_context.flag_key}: {exception}")

    def finally_after(self, hook_context, hints=None):
        print(f"[Hook] Done evaluating {hook_context.flag_key}")


def main():
    # 1. Register the provider
    provider = ${provider_init}
    api.set_provider(provider)

    # 2. Register hooks globally
    api.add_hooks([LoggingHook()])

    # 3. Create a client
    client = api.get_client("my-app")

    # 4. Build evaluation context
    context = EvaluationContext(
        targeting_key="user-123",
        attributes={
            "email": "user@example.com",
            "plan": "premium",
        },
    )

    # 5. Evaluate feature flags
    show_banner = client.get_boolean_value("show-welcome-banner", False, context)
    print(f"show-welcome-banner: {show_banner}")

    header_color = client.get_string_value("header-color", "blue", context)
    print(f"header-color: {header_color}")

    max_items = client.get_integer_value("max-items", 10, context)
    print(f"max-items: {max_items}")

    # 6. Clean up
    api.shutdown()


if __name__ == "__main__":
    main()
EOF
  write_file "$TARGET_DIR/openfeature_example.py" "$content"
}

generate_example_go() {
  local provider_import provider_init
  case "$PROVIDER" in
    flagd)
      provider_import='"github.com/open-feature/go-sdk-contrib/providers/flagd/pkg"'
      provider_init='flagd.NewProvider(flagd.WithHost("localhost"), flagd.WithPort(8013))' ;;
    launchdarkly)
      provider_import='"github.com/open-feature/go-sdk-contrib/providers/launchdarkly/pkg"'
      provider_init='launchdarkly.NewProvider("YOUR_SDK_KEY")' ;;
    unleash)
      provider_import='"github.com/open-feature/go-sdk-contrib/providers/unleash/pkg"'
      provider_init='unleash.NewProvider("http://localhost:4242/api", "my-app")' ;;
    flagsmith)
      provider_import='"github.com/open-feature/go-sdk-contrib/providers/flagsmith/pkg"'
      provider_init='flagsmith.NewProvider("YOUR_ENV_KEY")' ;;
  esac

  local content
  read -r -d '' content <<EOF || true
// OpenFeature Usage Example
//
// Demonstrates provider initialization, client creation,
// flag evaluation with context, and hook registration.
package main

import (
	"context"
	"fmt"
	"log"

	"github.com/open-feature/go-sdk/openfeature"
	${provider_import}
)

// LoggingHook is a custom hook that logs flag evaluations.
type LoggingHook struct{}

func (h LoggingHook) Before(ctx context.Context, hookCtx openfeature.HookContext, hints openfeature.HookHints) (*openfeature.EvaluationContext, error) {
	fmt.Printf("[Hook] Evaluating flag: %s\n", hookCtx.FlagKey())
	return nil, nil
}

func (h LoggingHook) After(ctx context.Context, hookCtx openfeature.HookContext, details openfeature.InterfaceEvaluationDetails, hints openfeature.HookHints) error {
	fmt.Printf("[Hook] Flag %s = %v\n", hookCtx.FlagKey(), details.Value)
	return nil
}

func (h LoggingHook) Error(ctx context.Context, hookCtx openfeature.HookContext, err error, hints openfeature.HookHints) {
	fmt.Printf("[Hook] Error evaluating %s: %v\n", hookCtx.FlagKey(), err)
}

func (h LoggingHook) Finally(ctx context.Context, hookCtx openfeature.HookContext, hints openfeature.HookHints) {
	fmt.Printf("[Hook] Done evaluating %s\n", hookCtx.FlagKey())
}

func main() {
	// 1. Register the provider
	provider := ${provider_init}
	openfeature.SetProvider(provider)

	// 2. Register hooks globally
	openfeature.AddHooks(LoggingHook{})

	// 3. Create a client
	client := openfeature.NewClient("my-app")

	// 4. Build evaluation context
	evalCtx := openfeature.NewEvaluationContext(
		"user-123",
		map[string]interface{}{
			"email": "user@example.com",
			"plan":  "premium",
		},
	)

	ctx := context.Background()

	// 5. Evaluate feature flags
	showBanner, err := client.BooleanValue(ctx, "show-welcome-banner", false, evalCtx)
	if err != nil {
		log.Printf("Error evaluating show-welcome-banner: %v", err)
	}
	fmt.Printf("show-welcome-banner: %v\n", showBanner)

	headerColor, err := client.StringValue(ctx, "header-color", "blue", evalCtx)
	if err != nil {
		log.Printf("Error evaluating header-color: %v", err)
	}
	fmt.Printf("header-color: %s\n", headerColor)

	maxItems, err := client.IntValue(ctx, "max-items", 10, evalCtx)
	if err != nil {
		log.Printf("Error evaluating max-items: %v", err)
	}
	fmt.Printf("max-items: %d\n", maxItems)

	// 6. Clean up
	openfeature.Shutdown()
}
EOF
  write_file "$TARGET_DIR/openfeature_example.go" "$content"
}

generate_example_java() {
  local provider_import provider_init
  case "$PROVIDER" in
    flagd)
      provider_import="import dev.openfeature.contrib.providers.flagd.FlagdProvider;"
      provider_init="new FlagdProvider()" ;;
    launchdarkly)
      provider_import="import dev.openfeature.contrib.providers.launchdarkly.LaunchDarklyProvider;"
      provider_init='new LaunchDarklyProvider("YOUR_SDK_KEY")' ;;
    unleash)
      provider_import="import dev.openfeature.contrib.providers.unleash.UnleashProvider;"
      provider_init='new UnleashProvider("http://localhost:4242/api", "my-app")' ;;
    flagsmith)
      provider_import="import dev.openfeature.contrib.providers.flagsmith.FlagsmithProvider;"
      provider_init='new FlagsmithProvider("YOUR_ENV_KEY")' ;;
  esac

  local content
  read -r -d '' content <<EOF || true
import dev.openfeature.sdk.OpenFeatureAPI;
import dev.openfeature.sdk.Client;
import dev.openfeature.sdk.MutableContext;
import dev.openfeature.sdk.Hook;
import dev.openfeature.sdk.HookContext;
import dev.openfeature.sdk.FlagEvaluationDetails;
${provider_import}

import java.util.Optional;

/**
 * OpenFeature Usage Example
 *
 * Demonstrates provider initialization, client creation,
 * flag evaluation with context, and hook registration.
 */
public class OpenFeatureExample {

    /**
     * Custom logging hook that logs every flag evaluation lifecycle event.
     */
    static class LoggingHook implements Hook<Object> {
        @Override
        public Optional<EvaluationContext> before(HookContext<Object> ctx, java.util.Map<String, Object> hints) {
            System.out.printf("[Hook] Evaluating flag: %s%n", ctx.getFlagKey());
            return Optional.empty();
        }

        @Override
        public void after(HookContext<Object> ctx, FlagEvaluationDetails<Object> details, java.util.Map<String, Object> hints) {
            System.out.printf("[Hook] Flag %s = %s%n", ctx.getFlagKey(), details.getValue());
        }

        @Override
        public void error(HookContext<Object> ctx, Exception error, java.util.Map<String, Object> hints) {
            System.out.printf("[Hook] Error evaluating %s: %s%n", ctx.getFlagKey(), error.getMessage());
        }

        @Override
        public void finallyAfter(HookContext<Object> ctx, java.util.Map<String, Object> hints) {
            System.out.printf("[Hook] Done evaluating %s%n", ctx.getFlagKey());
        }
    }

    public static void main(String[] args) {
        // 1. Register the provider
        OpenFeatureAPI api = OpenFeatureAPI.getInstance();
        api.setProvider(${provider_init});

        // 2. Register hooks globally
        api.addHooks(new LoggingHook());

        // 3. Create a client
        Client client = api.getClient("my-app");

        // 4. Build evaluation context
        MutableContext context = new MutableContext("user-123");
        context.add("email", "user@example.com");
        context.add("plan", "premium");

        // 5. Evaluate feature flags
        boolean showBanner = client.getBooleanValue("show-welcome-banner", false, context);
        System.out.println("show-welcome-banner: " + showBanner);

        String headerColor = client.getStringValue("header-color", "blue", context);
        System.out.println("header-color: " + headerColor);

        int maxItems = client.getIntegerValue("max-items", 10, context);
        System.out.println("max-items: " + maxItems);

        // 6. Clean up
        api.shutdown();
    }
}
EOF
  write_file "$TARGET_DIR/OpenFeatureExample.java" "$content"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  info "OpenFeature initializer — provider=$PROVIDER, dir=$TARGET_DIR"

  detect_language
  install_sdk
  create_config
  generate_example

  echo ""
  info "✅ OpenFeature setup complete for $DETECTED_LANG ($PROVIDER provider)."
  if $DRY_RUN; then
    info "This was a dry run — no files were modified."
  fi
}

main "$@"
