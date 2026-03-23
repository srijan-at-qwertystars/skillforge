# Review: aws-lambda-patterns

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format (positive:/negative: sub-keys).

Comprehensive Lambda skill. Covers handler patterns (single responsibility, DI, module-scope init), Middy middleware (Node.js), Lambda Powertools (Logger/Tracer/Metrics, APIGatewayRestResolver, parameters/secrets/idempotency), cold start optimization (SnapStart Python 3.12+/Java/.NET, Graviton ARM64, package size reduction, memory tuning), event sources (SQS/SNS/EventBridge/DynamoDB Streams/Kinesis/S3/API Gateway with retry/batch/scaling details), partial batch failure handling, error handling (DLQ, destinations), Lambda layers (5/function, 250MB limit), deployment (SAM vs CDK vs Serverless Framework comparison with templates), environment/configuration hierarchy, performance (1769MB=1vCPU, connection reuse, /tmp caching), testing (moto with mock_aws, LocalStack, SAM local), security (IAM least privilege, VPC, resource policies), observability (X-Ray, CloudWatch Logs Insights queries), and anti-patterns. Init Duration billing claim verified correct (Nov 2023 change).
