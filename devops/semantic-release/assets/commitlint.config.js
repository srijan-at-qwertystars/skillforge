/**
 * Commitlint configuration aligned with semantic-release conventions.
 *
 * Install:
 *   npm install --save-dev @commitlint/cli @commitlint/config-conventional
 *
 * Setup with Husky:
 *   npx husky init
 *   echo 'npx --no -- commitlint --edit "$1"' > .husky/commit-msg
 *
 * Test:
 *   echo "feat(auth): add login page" | npx commitlint
 *
 * @see https://commitlint.js.org/
 * @see https://www.conventionalcommits.org/
 */
module.exports = {
  extends: ['@commitlint/config-conventional'],

  rules: {
    // --- Type ---
    // Types that trigger releases in semantic-release:
    //   feat     → minor release
    //   fix      → patch release
    //   perf     → patch release (with custom releaseRules)
    //   revert   → patch release (with custom releaseRules)
    //
    // Types that do NOT trigger releases (but are valid commits):
    //   docs, style, refactor, test, build, ci, chore
    'type-enum': [
      2,
      'always',
      [
        'feat',     // New feature                         → minor
        'fix',      // Bug fix                             → patch
        'docs',     // Documentation only                  → no release
        'style',    // Code style (formatting, semicolons) → no release
        'refactor', // Code change (no feat/fix)           → no release (or patch w/ custom rules)
        'perf',     // Performance improvement             → no release (or patch w/ custom rules)
        'test',     // Adding/fixing tests                 → no release
        'build',    // Build system or dependencies        → no release
        'ci',       // CI configuration                    → no release
        'chore',    // Other changes                       → no release
        'revert',   // Revert a previous commit            → no release (or patch w/ custom rules)
      ],
    ],
    'type-case': [2, 'always', 'lower-case'],
    'type-empty': [2, 'never'],

    // --- Scope ---
    // Scope is optional but must be lowercase if provided
    'scope-case': [2, 'always', 'lower-case'],
    // Uncomment to enforce specific scopes:
    // 'scope-enum': [2, 'always', ['core', 'auth', 'api', 'ui', 'deps', 'config']],

    // --- Subject ---
    'subject-case': [
      2,
      'never',
      // Disallow these cases in the subject line
      ['sentence-case', 'start-case', 'pascal-case', 'upper-case'],
    ],
    'subject-empty': [2, 'never'],
    'subject-full-stop': [2, 'never', '.'],
    // Don't start the subject with a capital letter (conventional style)
    // Uncomment to enforce:
    // 'subject-exclamation-mark': [2, 'never'],

    // --- Header ---
    // The full first line (type(scope): subject) should be ≤ 100 chars
    'header-max-length': [2, 'always', 100],
    'header-min-length': [2, 'always', 10],

    // --- Body ---
    // Body lines should wrap at 200 chars (warning, not error)
    'body-max-line-length': [1, 'always', 200],
    'body-leading-blank': [2, 'always'],

    // --- Footer ---
    'footer-leading-blank': [2, 'always'],
    'footer-max-line-length': [1, 'always', 200],

    // --- Breaking Changes ---
    // BREAKING CHANGE footer is handled automatically by commitlint
    // The `!` notation (e.g., feat!: ...) is also supported

    // --- References ---
    // Allow issue references in various formats
    'references-empty': [0, 'never'],

    // --- Signed-off-by ---
    // Uncomment to require DCO sign-off:
    // 'signed-off-by': [2, 'always', 'Signed-off-by:'],

    // --- Trailer ---
    // Uncomment to require specific trailers:
    // 'trailer-exists': [1, 'always', 'Refs:'],
  },

  // Custom prompt configuration for commitizen (optional)
  prompt: {
    questions: {
      type: {
        description: 'Select the type of change',
        enum: {
          feat: {
            description: 'A new feature (triggers MINOR release)',
            title: 'Features',
            emoji: '✨',
          },
          fix: {
            description: 'A bug fix (triggers PATCH release)',
            title: 'Bug Fixes',
            emoji: '🐛',
          },
          docs: {
            description: 'Documentation only changes',
            title: 'Documentation',
            emoji: '📖',
          },
          style: {
            description: 'Changes that do not affect the meaning of the code',
            title: 'Styles',
            emoji: '💎',
          },
          refactor: {
            description: 'A code change that neither fixes a bug nor adds a feature',
            title: 'Code Refactoring',
            emoji: '📦',
          },
          perf: {
            description: 'A code change that improves performance',
            title: 'Performance Improvements',
            emoji: '🚀',
          },
          test: {
            description: 'Adding missing tests or correcting existing tests',
            title: 'Tests',
            emoji: '🚨',
          },
          build: {
            description: 'Changes that affect the build system or external dependencies',
            title: 'Builds',
            emoji: '🛠',
          },
          ci: {
            description: 'Changes to CI configuration files and scripts',
            title: 'Continuous Integration',
            emoji: '⚙️',
          },
          chore: {
            description: "Other changes that don't modify src or test files",
            title: 'Chores',
            emoji: '♻️',
          },
          revert: {
            description: 'Reverts a previous commit',
            title: 'Reverts',
            emoji: '🗑',
          },
        },
      },
    },
  },
};
