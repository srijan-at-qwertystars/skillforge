/**
 * Reusable L3 construct: Lambda + API Gateway REST API
 *
 * Features:
 *   - Lambda function with NodejsFunction (esbuild bundling)
 *   - API Gateway REST API with CORS
 *   - Access logging to CloudWatch
 *   - Optional custom domain with Route53
 *   - Configurable throttling and quota
 *   - CloudWatch alarms for errors and latency
 *
 * Usage:
 *   const api = new LambdaApi(this, 'Api', {
 *     entry: 'lambda/handler.ts',
 *     domainName: 'api.example.com',
 *     hostedZone: zone,
 *     certificate: cert,
 *   });
 *   api.handler;  // lambda.Function
 *   api.api;      // apigateway.RestApi
 */

import { Construct } from 'constructs';
import {
  Duration,
  RemovalPolicy,
  CfnOutput,
  Stack,
} from 'aws-cdk-lib';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as lambdaNode from 'aws-cdk-lib/aws-lambda-nodejs';
import * as apigw from 'aws-cdk-lib/aws-apigateway';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as acm from 'aws-cdk-lib/aws-certificatemanager';
import * as route53 from 'aws-cdk-lib/aws-route53';
import * as route53targets from 'aws-cdk-lib/aws-route53-targets';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';

// ---------------------------------------------------------------------------
// Props
// ---------------------------------------------------------------------------

export interface LambdaApiProps {
  /** Path to the Lambda handler entry file (TypeScript) */
  readonly entry: string;

  /** Lambda handler export name. @default 'handler' */
  readonly handlerName?: string;

  /** Lambda runtime. @default NODEJS_20_X */
  readonly runtime?: lambda.Runtime;

  /** Lambda memory in MB. @default 256 */
  readonly memorySize?: number;

  /** Lambda timeout. @default 30 seconds */
  readonly timeout?: Duration;

  /** Environment variables for Lambda */
  readonly environment?: Record<string, string>;

  /** Lambda reserved concurrency. @default no limit */
  readonly reservedConcurrency?: number;

  // --- API Gateway ---

  /** API name. @default construct id */
  readonly apiName?: string;

  /** API description */
  readonly apiDescription?: string;

  /** CORS allowed origins. @default ['*'] */
  readonly corsOrigins?: string[];

  /** CORS allowed methods. @default ['GET','POST','PUT','DELETE','OPTIONS'] */
  readonly corsMethods?: string[];

  /** Enable API Gateway access logging. @default true */
  readonly enableAccessLogs?: boolean;

  /** API throttling: requests per second. @default 100 */
  readonly throttlingRateLimit?: number;

  /** API throttling: burst limit. @default 200 */
  readonly throttlingBurstLimit?: number;

  // --- Custom Domain ---

  /** Custom domain name (e.g., 'api.example.com') */
  readonly domainName?: string;

  /** ACM certificate for the custom domain */
  readonly certificate?: acm.ICertificate;

  /** Route53 hosted zone for DNS record */
  readonly hostedZone?: route53.IHostedZone;

  // --- Monitoring ---

  /** Enable CloudWatch alarms. @default true */
  readonly enableAlarms?: boolean;

  /** Error rate threshold for alarm (percent). @default 5 */
  readonly errorRateThreshold?: number;

  /** P99 latency threshold for alarm (ms). @default 3000 */
  readonly latencyThreshold?: number;
}

// ---------------------------------------------------------------------------
// Construct
// ---------------------------------------------------------------------------

export class LambdaApi extends Construct {
  /** The Lambda function */
  public readonly handler: lambda.Function;

  /** The API Gateway REST API */
  public readonly api: apigw.RestApi;

  /** The access log group (if enabled) */
  public readonly accessLogGroup?: logs.LogGroup;

  /** The custom domain (if configured) */
  public readonly domainMapping?: apigw.DomainName;

  constructor(scope: Construct, id: string, props: LambdaApiProps) {
    super(scope, id);

    // --- Validation ---
    if (props.domainName && !props.certificate) {
      throw new Error('certificate is required when domainName is specified');
    }

    // --- Lambda Function ---
    this.handler = new lambdaNode.NodejsFunction(this, 'Handler', {
      entry: props.entry,
      handler: props.handlerName ?? 'handler',
      runtime: props.runtime ?? lambda.Runtime.NODEJS_20_X,
      memorySize: props.memorySize ?? 256,
      timeout: props.timeout ?? Duration.seconds(30),
      environment: props.environment,
      reservedConcurrentExecutions: props.reservedConcurrency,
      bundling: {
        minify: true,
        sourceMap: true,
        target: 'node20',
        externalModules: ['@aws-sdk/*'],
      },
      tracing: lambda.Tracing.ACTIVE,
    });

    // --- Access Logging ---
    const enableAccessLogs = props.enableAccessLogs ?? true;
    if (enableAccessLogs) {
      this.accessLogGroup = new logs.LogGroup(this, 'AccessLogs', {
        retention: logs.RetentionDays.THREE_MONTHS,
        removalPolicy: RemovalPolicy.DESTROY,
      });
    }

    // --- API Gateway ---
    const corsOrigins = props.corsOrigins ?? ['*'];
    const corsMethods = props.corsMethods ?? ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'];

    this.api = new apigw.RestApi(this, 'Api', {
      restApiName: props.apiName ?? id,
      description: props.apiDescription,
      deployOptions: {
        stageName: 'api',
        throttlingRateLimit: props.throttlingRateLimit ?? 100,
        throttlingBurstLimit: props.throttlingBurstLimit ?? 200,
        metricsEnabled: true,
        tracingEnabled: true,
        ...(this.accessLogGroup && {
          accessLogDestination: new apigw.LogGroupLogDestination(this.accessLogGroup),
          accessLogFormat: apigw.AccessLogFormat.jsonWithStandardFields({
            caller: true,
            httpMethod: true,
            ip: true,
            protocol: true,
            requestTime: true,
            resourcePath: true,
            responseLength: true,
            status: true,
            user: true,
          }),
        }),
      },
      defaultCorsPreflightOptions: {
        allowOrigins: corsOrigins,
        allowMethods: corsMethods,
        allowHeaders: [
          'Content-Type',
          'Authorization',
          'X-Amz-Date',
          'X-Api-Key',
          'X-Amz-Security-Token',
        ],
        maxAge: Duration.hours(1),
      },
    });

    // Default Lambda integration for the root
    const integration = new apigw.LambdaIntegration(this.handler);
    this.api.root.addMethod('ANY', integration);
    this.api.root.addProxy({ defaultIntegration: integration });

    // --- Custom Domain ---
    if (props.domainName && props.certificate) {
      this.domainMapping = this.api.addDomainName('CustomDomain', {
        domainName: props.domainName,
        certificate: props.certificate,
        endpointType: apigw.EndpointType.EDGE,
        securityPolicy: apigw.SecurityPolicy.TLS_1_2,
      });

      if (props.hostedZone) {
        new route53.ARecord(this, 'AliasRecord', {
          zone: props.hostedZone,
          recordName: props.domainName,
          target: route53.RecordTarget.fromAlias(
            new route53targets.ApiGateway(this.api)
          ),
        });
      }
    }

    // --- CloudWatch Alarms ---
    const enableAlarms = props.enableAlarms ?? true;
    if (enableAlarms) {
      // 5xx error rate alarm
      new cloudwatch.Alarm(this, 'ErrorAlarm', {
        metric: this.api.metricServerError({
          period: Duration.minutes(5),
          statistic: 'Sum',
        }),
        threshold: props.errorRateThreshold ?? 5,
        evaluationPeriods: 2,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
        alarmDescription: `API 5xx error rate exceeded threshold`,
      });

      // P99 latency alarm
      new cloudwatch.Alarm(this, 'LatencyAlarm', {
        metric: this.api.metricLatency({
          period: Duration.minutes(5),
          statistic: 'p99',
        }),
        threshold: props.latencyThreshold ?? 3000,
        evaluationPeriods: 3,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
        alarmDescription: `API p99 latency exceeded threshold`,
      });

      // Lambda error alarm
      new cloudwatch.Alarm(this, 'LambdaErrorAlarm', {
        metric: this.handler.metricErrors({
          period: Duration.minutes(5),
        }),
        threshold: 1,
        evaluationPeriods: 2,
        treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
        alarmDescription: `Lambda function errors detected`,
      });
    }

    // --- Outputs ---
    new CfnOutput(this, 'ApiUrl', {
      value: this.api.url,
      description: 'API Gateway endpoint URL',
    });

    if (props.domainName) {
      new CfnOutput(this, 'CustomDomainUrl', {
        value: `https://${props.domainName}`,
        description: 'Custom domain URL',
      });
    }

    new CfnOutput(this, 'FunctionName', {
      value: this.handler.functionName,
      description: 'Lambda function name',
    });
  }

  /** Grant invoke permissions on the underlying Lambda */
  public grantInvoke(grantee: lambda.IFunction | any): void {
    this.handler.grantInvoke(grantee);
  }

  /** Add an environment variable to the Lambda function */
  public addEnvironment(key: string, value: string): void {
    this.handler.addEnvironment(key, value);
  }
}
