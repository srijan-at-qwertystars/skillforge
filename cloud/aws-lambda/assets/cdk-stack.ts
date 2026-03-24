import { Stack, StackProps, CfnOutput, Duration, RemovalPolicy, Tags } from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as nodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as lambdaEventSources from 'aws-cdk-lib/aws-lambda-event-sources';
import * as path from 'path';
export interface ServiceStackProps extends StackProps {
  environment: 'dev' | 'staging' | 'prod';
  logRetentionDays?: number;
}

export class ServiceStack extends Stack {
  public readonly apiUrl: CfnOutput;
  public readonly tableName: CfnOutput;

  constructor(scope: Construct, id: string, props: ServiceStackProps) {
    super(scope, id, props);

    const { environment, logRetentionDays = 14 } = props;

    Tags.of(this).add('Environment', environment);
    Tags.of(this).add('ManagedBy', 'CDK');
    Tags.of(this).add('Service', 'my-service');

    // --- DynamoDB Table - single-table design with GSI ---
    const table = new dynamodb.Table(this, 'ItemsTable', {
      tableName: `${id}-items`,
      partitionKey: { name: 'PK', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'SK', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      pointInTimeRecovery: true,
      removalPolicy:
        environment === 'prod' ? RemovalPolicy.RETAIN : RemovalPolicy.DESTROY,
    });

    table.addGlobalSecondaryIndex({
      indexName: 'GSI1',
      partitionKey: { name: 'GSI1PK', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'GSI1SK', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    // --- SQS Queue with Dead-Letter Queue ---
    const dlq = new sqs.Queue(this, 'ProcessingDLQ', {
      queueName: `${id}-processing-dlq`,
      retentionPeriod: Duration.days(14),
    });

    const queue = new sqs.Queue(this, 'ProcessingQueue', {
      queueName: `${id}-processing`,
      visibilityTimeout: Duration.seconds(90),
      retentionPeriod: Duration.days(4),
      deadLetterQueue: {
        queue: dlq,
        maxReceiveCount: 3,
      },
    });

    // --- API Lambda - bundled with esbuild via NodejsFunction ---
    const apiFunction = new nodejs.NodejsFunction(this, 'ApiFunction', {
      functionName: `${id}-api`,
      entry: path.join(__dirname, '../src/api/index.ts'),
      handler: 'handler',
      runtime: lambda.Runtime.NODEJS_20_X,
      architecture: lambda.Architecture.ARM_64,
      memorySize: 256,
      timeout: Duration.seconds(15),
      tracing: lambda.Tracing.ACTIVE,
      environment: {
        ENVIRONMENT: environment,
        TABLE_NAME: table.tableName,
        QUEUE_URL: queue.queueUrl,
        NODE_OPTIONS: '--enable-source-maps',
      },
      bundling: {
        minify: true,
        sourceMap: true,
        target: 'node20',
        externalModules: ['@aws-sdk/*'],
      },
      logRetention: logs.RetentionDays[
        `${logRetentionDays === 14 ? 'TWO_WEEKS' : 'ONE_MONTH'}` as keyof typeof logs.RetentionDays
      ] ?? logs.RetentionDays.TWO_WEEKS,
    });

    // Scoped IAM grants
    table.grantReadWriteData(apiFunction);
    queue.grantSendMessages(apiFunction);

    // --- API Gateway REST API with CORS and request validation ---
    const api = new apigateway.RestApi(this, 'HttpApi', {
      restApiName: `${id}-api`,
      description: `${environment} environment API`,
      deployOptions: {
        stageName: environment,
        tracingEnabled: true,
        metricsEnabled: true,
        loggingLevel: apigateway.MethodLoggingLevel.INFO,
      },
      defaultCorsPreflightOptions: {
        allowOrigins: apigateway.Cors.ALL_ORIGINS,
        allowMethods: apigateway.Cors.ALL_METHODS,
        allowHeaders: ['Content-Type', 'Authorization', 'X-Request-Id'],
        maxAge: Duration.hours(1),
      },
    });

    const requestValidator = api.addRequestValidator('BodyValidator', {
      validateRequestBody: true,
    });

    api.root.addProxy({
      defaultIntegration: new apigateway.LambdaIntegration(apiFunction),
      anyMethod: true,
    });

    // --- SQS Consumer Lambda ---
    const queueProcessor = new nodejs.NodejsFunction(this, 'QueueProcessor', {
      functionName: `${id}-queue-processor`,
      entry: path.join(__dirname, '../src/queue-processor/index.ts'),
      handler: 'handler',
      runtime: lambda.Runtime.NODEJS_20_X,
      architecture: lambda.Architecture.ARM_64,
      memorySize: 256,
      timeout: Duration.seconds(15),
      tracing: lambda.Tracing.ACTIVE,
      environment: {
        ENVIRONMENT: environment,
        TABLE_NAME: table.tableName,
      },
      bundling: {
        minify: true,
        sourceMap: true,
        target: 'node20',
        externalModules: ['@aws-sdk/*'],
      },
    });

    // SQS event source with partial batch failure reporting
    queueProcessor.addEventSource(
      new lambdaEventSources.SqsEventSource(queue, {
        batchSize: 10,
        maxBatchingWindow: Duration.seconds(5),
        reportBatchItemFailures: true,
      }),
    );

    table.grantReadWriteData(queueProcessor);

    // --- CloudWatch Alarm ---
    new cloudwatch.Alarm(this, 'ApiErrorAlarm', {
      alarmName: `${id}-api-errors`,
      alarmDescription: 'Triggers when the API function error rate is elevated',
      metric: apiFunction.metricErrors({
        period: Duration.minutes(5),
        statistic: 'Sum',
      }),
      threshold: 5,
      evaluationPeriods: 1,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    // --- Stack Outputs ---
    this.apiUrl = new CfnOutput(this, 'ApiUrl', {
      value: api.url,
      description: 'REST API endpoint URL',
    });

    this.tableName = new CfnOutput(this, 'TableName', {
      value: table.tableName,
      description: 'DynamoDB table name',
    });

    new CfnOutput(this, 'ApiFunctionArn', {
      value: apiFunction.functionArn,
      description: 'API Lambda function ARN',
    });

    new CfnOutput(this, 'QueueUrl', {
      value: queue.queueUrl,
      description: 'SQS processing queue URL',
    });
  }
}
