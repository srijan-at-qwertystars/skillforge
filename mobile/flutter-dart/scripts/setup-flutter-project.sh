#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# setup-flutter-project.sh
# Scaffolds a Flutter project with clean architecture, common dependencies,
# and strict analysis options.
#
# Usage: ./setup-flutter-project.sh <project_name> [--org com.example]
# ============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Defaults ---------------------------------------------------------------
PROJECT_NAME=""
ORG="com.example"
FLUTTER_CMD="flutter"
DART_CMD="dart"

# --- Helpers ----------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") <project_name> [options]

Options:
  --org <org>       Organization identifier (default: com.example)
  --help            Show this help message

Example:
  $(basename "$0") my_app --org com.mycompany
EOF
  exit 0
}

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

check_prerequisites() {
  command -v "$FLUTTER_CMD" >/dev/null 2>&1 || error "Flutter not found. Install from https://flutter.dev"
  command -v "$DART_CMD" >/dev/null 2>&1    || error "Dart not found."
  info "Flutter $(flutter --version --machine 2>/dev/null | head -1 || flutter --version | head -1)"
}

# --- Parse Args -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)  ORG="$2"; shift 2 ;;
    --help) usage ;;
    -*)     error "Unknown option: $1" ;;
    *)      PROJECT_NAME="$1"; shift ;;
  esac
done

[[ -z "$PROJECT_NAME" ]] && error "Project name is required. Run with --help for usage."

# --- Preflight ---------------------------------------------------------------
check_prerequisites

if [[ -d "$PROJECT_NAME" ]]; then
  error "Directory '$PROJECT_NAME' already exists."
fi

# --- Create Project ----------------------------------------------------------
info "Creating Flutter project: $PROJECT_NAME (org: $ORG)"
$FLUTTER_CMD create --org "$ORG" --project-name "$PROJECT_NAME" "$PROJECT_NAME"
cd "$PROJECT_NAME"
ok "Project created"

# --- Create Clean Architecture Folder Structure ------------------------------
info "Setting up clean architecture folder structure..."

# Core directories
mkdir -p lib/core/{constants,extensions,theme,utils,network,errors}
mkdir -p lib/core/widgets

# Feature template (auth as example)
for feature in auth home; do
  mkdir -p "lib/features/$feature/data/datasources"
  mkdir -p "lib/features/$feature/data/models"
  mkdir -p "lib/features/$feature/data/repositories"
  mkdir -p "lib/features/$feature/domain/entities"
  mkdir -p "lib/features/$feature/domain/repositories"
  mkdir -p "lib/features/$feature/domain/usecases"
  mkdir -p "lib/features/$feature/presentation/pages"
  mkdir -p "lib/features/$feature/presentation/widgets"
  mkdir -p "lib/features/$feature/presentation/providers"
done

# Routing
mkdir -p lib/routing

# Test directories mirroring lib structure
mkdir -p test/core
mkdir -p test/features/auth/{data,domain,presentation}
mkdir -p test/features/home/{data,domain,presentation}
mkdir -p test/helpers
mkdir -p test/golden/goldens

# Integration tests
mkdir -p integration_test/robots

ok "Folder structure created"

# --- Create Placeholder Files ------------------------------------------------
info "Creating placeholder files..."

# Core constants
cat > lib/core/constants/app_constants.dart << 'DART'
abstract class AppConstants {
  static const String appName = 'MyApp';
  static const Duration defaultTimeout = Duration(seconds: 30);
  static const int defaultPageSize = 20;
}
DART

# Core errors
cat > lib/core/errors/failures.dart << 'DART'
sealed class Failure {
  final String message;
  const Failure(this.message);
}

class ServerFailure extends Failure {
  const ServerFailure([super.message = 'Server error occurred']);
}

class CacheFailure extends Failure {
  const CacheFailure([super.message = 'Cache error occurred']);
}

class NetworkFailure extends Failure {
  const NetworkFailure([super.message = 'No internet connection']);
}
DART

# Core extensions
cat > lib/core/extensions/context_extensions.dart << 'DART'
import 'package:flutter/material.dart';

extension BuildContextX on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colorScheme => theme.colorScheme;
  TextTheme get textTheme => theme.textTheme;
  Size get screenSize => MediaQuery.sizeOf(this);
  double get screenWidth => screenSize.width;
  double get screenHeight => screenSize.height;
  bool get isSmallScreen => screenWidth < 600;
  bool get isMediumScreen => screenWidth >= 600 && screenWidth < 900;
  bool get isLargeScreen => screenWidth >= 900;
}
DART

# Routing
cat > lib/routing/app_router.dart << 'DART'
import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';

abstract class AppRoutes {
  static const home = '/';
  static const login = '/login';
  static const settings = '/settings';
}

final appRouter = GoRouter(
  initialLocation: AppRoutes.home,
  routes: [
    GoRoute(
      path: AppRoutes.home,
      builder: (context, state) => const Scaffold(
        body: Center(child: Text('Home')),
      ),
    ),
  ],
  errorBuilder: (context, state) => Scaffold(
    body: Center(child: Text('Page not found: ${state.uri}')),
  ),
);
DART

# App root
cat > lib/app.dart << 'DART'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'routing/app_router.dart';
import 'core/theme/app_theme.dart';

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'MyApp',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: appRouter,
      debugShowCheckedModeBanner: false,
    );
  }
}
DART

# Main entry point
cat > lib/main.dart << 'DART'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const ProviderScope(
      child: App(),
    ),
  );
}
DART

# Theme
cat > lib/core/theme/app_theme.dart << 'DART'
import 'package:flutter/material.dart';

abstract class AppTheme {
  static final light = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: Brightness.light,
    ),
  );

  static final dark = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.indigo,
      brightness: Brightness.dark,
    ),
  );
}
DART

# Test helper
cat > test/helpers/test_helpers.dart << 'DART'
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Wraps a widget with MaterialApp and ProviderScope for testing
Widget createTestWidget({
  required Widget child,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(home: child),
  );
}
DART

ok "Placeholder files created"

# --- Add Dependencies -------------------------------------------------------
info "Adding common dependencies..."

# Production dependencies
$FLUTTER_CMD pub add \
  flutter_riverpod \
  riverpod_annotation \
  go_router \
  dio \
  freezed_annotation \
  json_annotation \
  shared_preferences \
  flutter_secure_storage \
  intl

# Dev dependencies
$FLUTTER_CMD pub add --dev \
  riverpod_generator \
  build_runner \
  freezed \
  json_serializable \
  mocktail \
  riverpod_lint \
  custom_lint

ok "Dependencies added"

# --- Configure Analysis Options ---------------------------------------------
info "Configuring analysis options..."

cat > analysis_options.yaml << 'YAML'
include: package:flutter_lints/flutter.yaml

analyzer:
  plugins:
    - custom_lint
  exclude:
    - "**/*.g.dart"
    - "**/*.freezed.dart"
    - "**/*.gr.dart"
    - "build/**"
    - "**/*.gen.dart"
  errors:
    invalid_annotation_target: ignore
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true

linter:
  rules:
    # Error rules
    - always_use_package_imports
    - avoid_dynamic_calls
    - avoid_returning_null_for_future
    - avoid_slow_async_io
    - avoid_type_to_string
    - cancel_subscriptions
    - close_sinks
    - literal_only_boolean_expressions
    - no_adjacent_strings_in_list
    - throw_in_finally
    - unnecessary_statements

    # Style rules
    - always_declare_return_types
    - annotate_overrides
    - avoid_bool_literals_in_conditional_expressions
    - avoid_catches_without_on_clauses
    - avoid_catching_errors
    - avoid_classes_with_only_static_members
    - avoid_field_initializers_in_const_classes
    - avoid_final_parameters
    - avoid_multiple_declarations_per_line
    - avoid_positional_boolean_parameters
    - avoid_private_typedef_functions
    - avoid_redundant_argument_values
    - avoid_returning_this
    - avoid_setters_without_getters
    - avoid_unused_constructor_parameters
    - avoid_void_async
    - cascade_invocations
    - cast_nullable_to_non_nullable
    - combinators_ordering
    - conditional_uri_does_not_exist
    - deprecated_consistency
    - directives_ordering
    - eol_at_end_of_file
    - join_return_with_assignment
    - leading_newlines_in_multiline_strings
    - missing_whitespace_between_adjacent_strings
    - no_literal_bool_comparisons
    - no_runtimeType_toString
    - noop_primitive_operations
    - omit_local_variable_types
    - one_member_abstracts
    - only_throw_errors
    - parameter_assignments
    - prefer_asserts_in_initializer_lists
    - prefer_const_constructors
    - prefer_const_constructors_in_immutables
    - prefer_const_declarations
    - prefer_const_literals_to_create_immutables
    - prefer_constructors_over_static_methods
    - prefer_expression_function_bodies
    - prefer_final_in_for_each
    - prefer_final_locals
    - prefer_if_elements_to_conditional_expressions
    - prefer_int_literals
    - prefer_mixin
    - prefer_null_aware_method_calls
    - prefer_single_quotes
    - require_trailing_commas
    - sized_box_shrink_expand
    - sort_constructors_first
    - sort_unnamed_constructors_first
    - type_annotate_public_apis
    - unawaited_futures
    - unnecessary_await_in_return
    - unnecessary_breaks
    - unnecessary_lambdas
    - unnecessary_null_aware_assignments
    - unnecessary_null_checks
    - unnecessary_parenthesis
    - unnecessary_raw_strings
    - unnecessary_to_list_if_not_growable
    - unreachable_from_main
    - use_colored_box
    - use_decorated_box
    - use_enums
    - use_if_null_to_convert_nulls_to_bools
    - use_is_even_rather_than_modulo
    - use_named_constants
    - use_raw_strings
    - use_setters_to_change_properties
    - use_string_buffers
    - use_super_parameters
    - use_to_and_as_if_applicable
YAML

ok "Analysis options configured"

# --- Resolve Dependencies ----------------------------------------------------
info "Resolving dependencies..."
$FLUTTER_CMD pub get
ok "Dependencies resolved"

# --- Summary -----------------------------------------------------------------
echo ""
echo "============================================"
ok "Project '$PROJECT_NAME' scaffolded successfully!"
echo "============================================"
echo ""
echo "Project structure:"
echo "  lib/"
echo "    core/        — shared utilities, theme, extensions, errors"
echo "    features/    — feature-first modules (auth, home)"
echo "    routing/     — GoRouter configuration"
echo "    app.dart     — MaterialApp.router root"
echo "    main.dart    — bootstrap with ProviderScope"
echo "  test/          — unit and widget tests"
echo "  integration_test/ — integration tests"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_NAME"
echo "  flutter run"
echo ""
