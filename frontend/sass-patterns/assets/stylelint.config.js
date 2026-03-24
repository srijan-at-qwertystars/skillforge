// stylelint.config.js — Production Stylelint configuration for SCSS
// Install: npm i -D stylelint stylelint-config-standard-scss stylelint-order
// Run:     npx stylelint "src/**/*.{scss,css}"
// Autofix: npx stylelint "src/**/*.{scss,css}" --fix

/** @type {import('stylelint').Config} */
module.exports = {
  extends: ['stylelint-config-standard-scss'],
  plugins: ['stylelint-order'],
  rules: {
    // ─── Nesting & Specificity ───────────────────────────
    'max-nesting-depth': [
      3,
      {
        ignoreAtRules: ['media', 'supports', 'container', 'include', 'each', 'if', 'else'],
        message: 'Nesting deeper than 3 levels — flatten with BEM naming',
      },
    ],
    'selector-max-compound-selectors': 4,
    'selector-max-id': 0,
    'selector-max-specificity': ['0,4,0', { message: 'Reduce selector specificity' }],
    'selector-no-qualifying-type': [true, { ignore: ['attribute', 'class'] }],

    // ─── Naming Conventions ──────────────────────────────
    // BEM pattern: block__element--modifier
    'selector-class-pattern': [
      '^[a-z][a-z0-9]*(-[a-z0-9]+)*(__[a-z0-9]+(-[a-z0-9]+)*)*(--[a-z0-9]+(-[a-z0-9]+)*)?$',
      { message: 'Use BEM: .block__element--modifier (%(selector))' },
    ],
    'keyframes-name-pattern': '^[a-z][a-z0-9]*(-[a-z0-9]+)*$',
    'scss/dollar-variable-pattern': '^[a-z][a-z0-9]*(-[a-z0-9]+)*$',
    'scss/percent-placeholder-pattern': '^[a-z][a-z0-9]*(-[a-z0-9]+)*$',
    'scss/at-mixin-pattern': '^[a-z][a-z0-9]*(-[a-z0-9]+)*$',

    // ─── SCSS-Specific ───────────────────────────────────
    'scss/no-global-function-names': true,
    'scss/at-rule-no-unknown': [
      true,
      { ignoreAtRules: ['tailwind', 'apply', 'layer', 'container', 'screen'] },
    ],
    'scss/at-import-no-partial-leading-underscore': true,
    'scss/comment-no-empty': true,
    'scss/no-duplicate-dollar-variables': [true, { ignoreInside: ['at-rule', 'nested-at-rule'] }],
    'scss/no-duplicate-mixins': true,

    // ─── Best Practices ──────────────────────────────────
    'declaration-block-no-redundant-longhand-properties': true,
    'shorthand-property-no-redundant-values': true,
    'declaration-no-important': [true, { severity: 'warning', message: 'Avoid !important — fix specificity instead' }],
    'color-named': 'never',
    'color-no-hex': null,
    'font-weight-notation': 'numeric',
    'no-descending-specificity': [true, { severity: 'warning' }],
    'no-duplicate-selectors': true,
    'declaration-block-single-line-max-declarations': 1,

    // ─── Property Order ──────────────────────────────────
    'order/order': [
      'custom-properties',
      'dollar-variables',
      { type: 'at-rule', name: 'extend' },
      { type: 'at-rule', name: 'include', hasBlock: false },
      'declarations',
      { type: 'at-rule', name: 'include', hasBlock: true },
      'rules',
      { type: 'at-rule', name: 'media' },
    ],
    'order/properties-order': [
      // Positioning
      { groupName: 'position', properties: ['position', 'inset', 'top', 'right', 'bottom', 'left', 'z-index'] },
      // Display & Flex/Grid
      { groupName: 'display', properties: ['display', 'flex', 'flex-direction', 'flex-wrap', 'justify-content', 'align-items', 'align-content', 'gap', 'order', 'flex-grow', 'flex-shrink', 'flex-basis'] },
      { groupName: 'grid', properties: ['grid', 'grid-template-columns', 'grid-template-rows', 'grid-template-areas', 'grid-auto-flow', 'grid-column', 'grid-row'] },
      // Box model
      { groupName: 'box-model', properties: ['width', 'min-width', 'max-width', 'height', 'min-height', 'max-height', 'margin', 'padding', 'overflow', 'box-sizing'] },
      // Typography
      { groupName: 'typography', properties: ['font', 'font-family', 'font-size', 'font-weight', 'line-height', 'letter-spacing', 'text-align', 'text-decoration', 'text-transform', 'white-space', 'word-break', 'color'] },
      // Visual
      { groupName: 'visual', properties: ['background', 'border', 'border-radius', 'box-shadow', 'opacity', 'outline', 'visibility'] },
      // Animation
      { groupName: 'animation', properties: ['transition', 'animation', 'transform', 'will-change'] },
    ],
  },
  ignoreFiles: [
    '**/node_modules/**',
    '**/dist/**',
    '**/build/**',
    '**/coverage/**',
    '**/*.min.css',
    '**/vendor/**',
  ],
};
