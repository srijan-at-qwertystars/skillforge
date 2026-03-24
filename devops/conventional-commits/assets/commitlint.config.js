/**
 * commitlint.config.js — Production commitlint configuration
 *
 * Copy this file to your project root and customize as needed.
 *
 * Usage:
 *   cp commitlint.config.js /path/to/project/
 *   echo "feat(auth): add login" | npx commitlint
 *
 * Docs: https://commitlint.js.org/reference/rules-configuration.html
 */

const { readdirSync, existsSync } = require('fs');
const { resolve } = require('path');

// --- Dynamic scope extraction (monorepo-aware) ---
function getPackageScopes() {
  const dirs = ['packages', 'apps', 'libs', 'modules', 'services'];
  const scopes = [];
  for (const dir of dirs) {
    const fullPath = resolve(__dirname, dir);
    if (!existsSync(fullPath)) continue;
    const entries = readdirSync(fullPath, { withFileTypes: true });
    scopes.push(...entries.filter(e => e.isDirectory()).map(e => e.name));
  }
  return scopes;
}

// Base scopes always allowed (add your project-specific scopes here)
const BASE_SCOPES = [
  'repo',     // repo-wide changes
  'deps',     // dependency updates
  'release',  // release automation
  'config',   // configuration changes
];

const packageScopes = getPackageScopes();
const allScopes = [...BASE_SCOPES, ...packageScopes];

module.exports = {
  extends: ['@commitlint/config-conventional'],

  rules: {
    // ============================================================
    // Header rules
    // ============================================================
    'header-max-length': [2, 'always', 100],
    'header-min-length': [2, 'always', 10],
    'header-trim': [2, 'always'],

    // ============================================================
    // Type rules
    // ============================================================
    'type-case': [2, 'always', 'lower-case'],
    'type-empty': [2, 'never'],
    'type-enum': [2, 'always', [
      // Standard types
      'feat',       // New feature (MINOR bump)
      'fix',        // Bug fix (PATCH bump)
      'docs',       // Documentation only
      'style',      // Formatting, whitespace, semicolons
      'refactor',   // Code restructuring (no feature/fix)
      'perf',       // Performance improvement (PATCH bump)
      'test',       // Adding or correcting tests
      'build',      // Build system or external dependencies
      'ci',         // CI/CD configuration
      'chore',      // Maintenance tasks
      'revert',     // Revert a previous commit

      // Custom types (uncomment as needed)
      // 'hotfix',   // Emergency production fix
      // 'security', // Security patches
      // 'deps',     // Dependency updates
      // 'i18n',     // Internationalization
      // 'a11y',     // Accessibility
    ]],

    // ============================================================
    // Scope rules
    // ============================================================
    'scope-case': [2, 'always', 'lower-case'],
    'scope-empty': [0],  // Scope is optional; set to [2, 'never'] to require
    // Uncomment to enforce scope allowlist:
    // 'scope-enum': [2, 'always', allScopes],

    // ============================================================
    // Subject (description) rules
    // ============================================================
    'subject-case': [2, 'never', [
      'start-case',   // No "Add Feature"
      'pascal-case',  // No "AddFeature"
      'upper-case',   // No "ADD FEATURE"
    ]],
    'subject-empty': [2, 'never'],
    'subject-full-stop': [2, 'never', '.'],
    'subject-exclamation-mark': [0],  // Allow ! for breaking changes

    // ============================================================
    // Body rules
    // ============================================================
    'body-leading-blank': [2, 'always'],   // Blank line between header and body
    'body-max-line-length': [2, 'always', 200],
    'body-empty': [0],                     // Body is optional

    // ============================================================
    // Footer rules
    // ============================================================
    'footer-leading-blank': [2, 'always'],  // Blank line before footers
    'footer-max-line-length': [2, 'always', 200],

    // ============================================================
    // Trailer rules
    // ============================================================
    // Require Signed-off-by for DCO compliance (uncomment if needed):
    // 'signed-off-by': [2, 'always', 'Signed-off-by:'],

    // Require a specific trailer (uncomment if needed):
    // 'trailer-exists': [1, 'always', 'Refs:'],
  },

  // ============================================================
  // Custom plugins
  // ============================================================
  plugins: [
    {
      rules: {
        /**
         * Enforce imperative mood — reject past tense in subject.
         * "added feature" → error; "add feature" → ok
         */
        'subject-imperative': ({ subject }) => {
          if (!subject) return [true];
          const pastTensePatterns = /^(added|fixed|removed|updated|changed|deleted|created|modified|implemented|refactored|improved|resolved)\b/i;
          return [
            !pastTensePatterns.test(subject),
            'subject must use imperative mood (e.g., "add" not "added")',
          ];
        },

        /**
         * Warn if commit subject is too vague / generic.
         */
        'subject-no-generic': ({ subject }) => {
          if (!subject) return [true];
          const generic = /^(update|fix|change|modify|improve|refactor|clean up|misc|wip|stuff|things)$/i;
          return [
            !generic.test(subject.trim()),
            'subject is too vague — be specific about what changed',
          ];
        },
      },
    },
  ],

  // Apply custom plugin rules (severity 1 = warning)
  // Override in rules above if you want errors instead
  // Note: plugin rule names are referenced in the rules object above
  // To activate them, uncomment below:
  // 'subject-imperative': [1, 'always'],
  // 'subject-no-generic': [1, 'always'],

  // ============================================================
  // Ignore patterns
  // ============================================================
  ignores: [
    // Skip merge commits
    (message) => /^Merge /.test(message),
    // Skip release commits from automation
    (message) => /^chore\(release\):/.test(message),
  ],

  // ============================================================
  // Prompt configuration (for @commitlint/cz-commitlint)
  // ============================================================
  prompt: {
    settings: {
      enableMultipleScopes: false,
      scopeEnumSeparator: ',',
    },
    messages: {
      skip: '(press enter to skip)',
      max: '(max %d chars)',
      emptyWarning: 'cannot be empty',
      upperLimitWarning: 'over limit',
    },
    questions: {
      type: {
        description: "Select the type of change you're committing:",
        enum: {
          feat:     { description: 'A new feature',                  title: 'Features',     emoji: '✨' },
          fix:      { description: 'A bug fix',                      title: 'Bug Fixes',    emoji: '🐛' },
          docs:     { description: 'Documentation only changes',     title: 'Documentation',emoji: '📚' },
          style:    { description: 'Formatting, whitespace, etc.',   title: 'Styles',       emoji: '💎' },
          refactor: { description: 'Code change (no fix/feature)',   title: 'Refactoring',  emoji: '📦' },
          perf:     { description: 'A performance improvement',      title: 'Performance',  emoji: '🚀' },
          test:     { description: 'Adding or fixing tests',         title: 'Tests',        emoji: '🚨' },
          build:    { description: 'Build system or dependencies',   title: 'Build',        emoji: '🛠' },
          ci:       { description: 'CI configuration changes',       title: 'CI',           emoji: '⚙️' },
          chore:    { description: 'Other maintenance tasks',        title: 'Chores',       emoji: '♻️' },
          revert:   { description: 'Reverts a previous commit',      title: 'Reverts',      emoji: '🗑' },
        },
      },
    },
  },
};
