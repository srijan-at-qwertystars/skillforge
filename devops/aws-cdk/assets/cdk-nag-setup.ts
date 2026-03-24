/**
 * cdk-nag integration setup with AwsSolutions pack and suppression patterns.
 *
 * cdk-nag validates CDK applications against compliance rule packs
 * (AwsSolutions, HIPAA, NIST 800-53, PCI DSS) and reports violations
 * as synthesis warnings/errors.
 *
 * Usage:
 *   npm install cdk-nag
 *
 *   // In your app entry point:
 *   import { applyNagChecks } from './cdk-nag-setup';
 *   const app = new cdk.App();
 *   new MyStack(app, 'MyStack');
 *   applyNagChecks(app);
 *
 *   // In tests:
 *   import { assertNagCompliant } from './cdk-nag-setup';
 *   assertNagCompliant(stack);
 */

import { App, Stack, Aspects } from 'aws-cdk-lib';
import { Annotations, Match } from 'aws-cdk-lib/assertions';
import {
  AwsSolutionsChecks,
  HIPAASecurityChecks,
  NIST80053R5Checks,
  NagSuppressions,
  NagPackSuppression,
} from 'cdk-nag';
import { IConstruct } from 'constructs';

// ---------------------------------------------------------------------------
// Rule packs
// ---------------------------------------------------------------------------

export type NagRulePack = 'aws-solutions' | 'hipaa' | 'nist-800-53';

/**
 * Apply cdk-nag checks to the entire application.
 *
 * @param app - CDK App instance
 * @param packs - Rule packs to enable. Default: ['aws-solutions']
 * @param verbose - Show detailed rule descriptions. Default: true
 */
export function applyNagChecks(
  app: App,
  packs: NagRulePack[] = ['aws-solutions'],
  verbose = true
): void {
  for (const pack of packs) {
    switch (pack) {
      case 'aws-solutions':
        Aspects.of(app).add(new AwsSolutionsChecks({ verbose }));
        break;
      case 'hipaa':
        Aspects.of(app).add(new HIPAASecurityChecks({ verbose }));
        break;
      case 'nist-800-53':
        Aspects.of(app).add(new NIST80053R5Checks({ verbose }));
        break;
    }
  }
}

// ---------------------------------------------------------------------------
// Common suppression patterns
// ---------------------------------------------------------------------------

/**
 * Commonly suppressed rules with documented justifications.
 * Use these as a starting point and customize for your organization.
 */
export const COMMON_SUPPRESSIONS: Record<string, NagPackSuppression[]> = {
  /** Suppress managed policy warnings for Lambda execution roles */
  lambdaManagedPolicies: [
    {
      id: 'AwsSolutions-IAM4',
      reason:
        'AWS managed policies (AWSLambdaBasicExecutionRole) are acceptable ' +
        'for Lambda execution roles providing CloudWatch Logs access.',
    },
  ],

  /** Suppress wildcard permissions for CDK custom resources */
  cdkCustomResources: [
    {
      id: 'AwsSolutions-IAM5',
      reason:
        'CDK custom resource framework requires wildcard permissions to ' +
        'manage resources across the account during deployment.',
    },
  ],

  /** Suppress Cognito password requirements (when using external IdP) */
  cognitoExternalIdp: [
    {
      id: 'AwsSolutions-COG1',
      reason: 'Password policy not applicable when using external IdP federation.',
    },
    {
      id: 'AwsSolutions-COG2',
      reason: 'MFA handled by external identity provider.',
    },
  ],

  /** Suppress S3 access logging (when using CloudTrail instead) */
  s3CloudTrailLogging: [
    {
      id: 'AwsSolutions-S1',
      reason: 'S3 access logging handled at account level via CloudTrail data events.',
    },
  ],

  /** Suppress API Gateway auth (for public endpoints) */
  publicApiEndpoints: [
    {
      id: 'AwsSolutions-APIG4',
      reason: 'Public API endpoint — authentication handled at application layer.',
    },
    {
      id: 'AwsSolutions-COG4',
      reason: 'Cognito authorizer not required for public endpoints.',
    },
  ],

  /** Suppress CloudWatch log encryption (for non-sensitive logs) */
  logEncryption: [
    {
      id: 'AwsSolutions-CW27',
      reason: 'CloudWatch log encryption not required for non-sensitive operational logs.',
    },
  ],
};

// ---------------------------------------------------------------------------
// Suppression helpers
// ---------------------------------------------------------------------------

/**
 * Apply suppressions to a stack.
 */
export function suppressStackRules(
  stack: Stack,
  suppressions: NagPackSuppression[],
  applyToChildren = true
): void {
  NagSuppressions.addStackSuppressions(stack, suppressions, applyToChildren);
}

/**
 * Apply suppressions to a specific construct.
 */
export function suppressResourceRules(
  construct: IConstruct,
  suppressions: NagPackSuppression[]
): void {
  NagSuppressions.addResourceSuppressions(construct, suppressions);
}

/**
 * Apply suppressions by resource path (useful for nested constructs).
 */
export function suppressByPath(
  stack: Stack,
  path: string,
  suppressions: NagPackSuppression[]
): void {
  NagSuppressions.addResourceSuppressionsByPath(stack, path, suppressions);
}

/**
 * Apply common Lambda suppressions to a stack.
 * Suppresses managed policy and wildcard resource warnings that are
 * standard for Lambda-based architectures.
 */
export function suppressLambdaDefaults(stack: Stack): void {
  suppressStackRules(stack, [
    ...COMMON_SUPPRESSIONS.lambdaManagedPolicies,
    ...COMMON_SUPPRESSIONS.cdkCustomResources,
  ]);
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/**
 * Assert that a stack has no cdk-nag errors.
 * Use in Jest tests:
 *
 *   test('passes cdk-nag', () => {
 *     const stack = new MyStack(app, 'Test');
 *     assertNagCompliant(stack);
 *   });
 */
export function assertNagCompliant(
  stack: Stack,
  packs: NagRulePack[] = ['aws-solutions']
): void {
  const app = stack.node.root as App;
  applyNagChecks(app, packs, true);
  app.synth();

  const errors = Annotations.fromStack(stack).findError(
    '*',
    Match.stringLikeRegexp('.*')
  );

  if (errors.length > 0) {
    const messages = errors
      .map((e) => `  - ${e.id}: ${e.entry.data}`)
      .join('\n');
    throw new Error(`cdk-nag found ${errors.length} error(s):\n${messages}`);
  }
}

/**
 * Get all cdk-nag warnings for a stack (for review, not failure).
 */
export function getNagWarnings(
  stack: Stack,
  packs: NagRulePack[] = ['aws-solutions']
): Array<{ id: string; message: string }> {
  const app = stack.node.root as App;
  applyNagChecks(app, packs, true);
  app.synth();

  return Annotations.fromStack(stack)
    .findWarning('*', Match.stringLikeRegexp('.*'))
    .map((w) => ({
      id: w.id,
      message: String(w.entry.data),
    }));
}

// ---------------------------------------------------------------------------
// Example usage in app entry point
// ---------------------------------------------------------------------------
/*
import * as cdk from 'aws-cdk-lib';
import { MyStack } from '../lib/my-stack';
import { applyNagChecks, suppressLambdaDefaults, COMMON_SUPPRESSIONS } from './cdk-nag-setup';

const app = new cdk.App();
const stack = new MyStack(app, 'MyStack');

// Apply standard Lambda suppressions
suppressLambdaDefaults(stack);

// Apply custom suppressions
suppressStackRules(stack, COMMON_SUPPRESSIONS.s3CloudTrailLogging);

// Enable compliance checks
applyNagChecks(app, ['aws-solutions']);

app.synth();
*/
