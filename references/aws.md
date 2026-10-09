# AWS (Lambda, S3, SQS, API Gateway, DynamoDB, networking)

AWS **Budgets alert but do not stop spend**, except when a Budget Action applies an IAM or
SCP deny policy. Incidents include $1.3k on an empty private S3 bucket (unauthorized requests;
AWS stopped billing most of these in 2024), $4.2k on a "paused" service, and charges while on
the free tier.

## Loop patterns

### AWS-LOOP-1: S3 trigger writes to the same bucket

```ts
// Lambda subscribed to s3:ObjectCreated:* on bucket "uploads"
await s3.send(new PutObjectCommand({ Bucket: 'uploads', Key: `resized/${key}`, Body }));
```

Find the trigger in IaC: `aws_s3_bucket_notification`, CDK `addEventNotification` /
`S3EventSource`, SAM `Events: Type: S3`, `serverless.yml` `events: - s3:`. Compare the bucket
and the prefix/suffix filter with every bucket the function writes to. If the output can match
the filter, it is a loop.

Fix: write to a different bucket, or use a prefix filter on the trigger that the output can
never match.

### AWS-LOOP-2: SQS / SNS / EventBridge re-publish

A consumer that sends to its own queue or topic, or an EventBridge rule that matches events the
target emits. Lambda recursive loop detection stops some Lambda ↔ SQS/SNS/S3 loops after about
16 iterations, but not all paths (for example EventBridge, Step Functions, HTTP self-calls).
Do not depend on it, and check that it was not turned off (`RecursiveLoop: Allow`).

### AWS-LOOP-3: Retries with no cap

- SQS: a redrive policy with `maxReceiveCount` and a DLQ. Without it, a poison message is retried
  until retention ends (up to 14 days).
- Lambda async: `MaximumRetryAttempts`, `MaximumEventAgeInSeconds`, an on-failure destination.
- Event source mappings (Kinesis/DynamoDB Streams): `MaximumRetryAttempts` default is -1
  (infinite) and one bad record blocks the shard. Set `BisectBatchOnFunctionError` and a cap.
- Step Functions: `Retry` with a high `MaxAttempts`, or a loop state with no counter.

## Abuse and egress patterns

- **AWS-ABUSE-1: Public buckets.** `PublicRead`, `public-read` ACL, `BlockPublicAccess.BLOCK_NONE`,
  `block_public_acls = false`, a bucket policy with `"Principal": "*"`. Large public objects =
  egress at ≈$0.09/GB. Put CloudFront in front with a budget and WAF.
- **AWS-ABUSE-2: Presigned upload URLs** with no `Content-Length` limit (use
  `createPresignedPost` with a `content-length-range` condition), a long expiry, or no auth on
  the route that creates them.
- **AWS-ABUSE-3: API Gateway with no throttling.** Look for stage `ThrottlingRateLimit` /
  `ThrottlingBurstLimit`, usage plans, and a WAF rate-based rule. Lambda Function URLs with
  `AuthType: NONE` have no throttle other than concurrency.
- **AWS-EGRESS-1: NAT Gateway.** Lambdas in a VPC that call public APIs or S3 through a NAT pay
  ≈$0.045/GB processed plus hourly fees. Add S3/DynamoDB gateway endpoints.
- **AWS-EGRESS-2: Cross-AZ / cross-region transfer** in chatty services.

## Hot-path patterns

- **AWS-HOT-1: DynamoDB `Scan`** on request paths. Billed by data read, not by items returned.
- **AWS-HOT-2: CloudWatch Logs volume.** Debug logs or full payload logs in high-traffic
  Lambdas. Ingestion is ≈$0.50/GB. Set log retention (`RetentionInDays`); the default is forever.
- **AWS-HOT-3: Lambda memory/timeout** set to max (10 GB, 900 s) on public routes.
- **AWS-HOT-4: Provisioned resources left on**: provisioned concurrency, NAT gateways, RDS,
  OpenSearch, idle load balancers. These bill when "paused".

## Guardrails to look for

| Guardrail | Where |
|---|---|
| `ReservedConcurrentExecutions` | Lambda function config (CDK `reservedConcurrentExecutions`, TF `reserved_concurrent_executions`) |
| `maxReceiveCount` + DLQ | SQS redrive policy |
| `MaximumRetryAttempts` | async invoke config, event source mappings |
| Stage throttling, usage plans, WAF | API Gateway |
| `AWS::Budgets::Budget` / `aws_budgets_budget` / `CfnBudget` | IaC |
| Budget Actions (IAM/SCP deny) | IaC or console |
| Cost Anomaly Detection monitor | `aws_ce_anomaly_monitor` or console |
| `RetentionInDays` | log groups |

## Approximate unit prices (as of 2026-10; verify on the current pricing page, us-east-1)

| Unit | ≈ Price |
|---|---|
| Lambda requests / compute | $0.20 / M, $0.0000166667 / GB-s |
| S3 PUT/LIST / GET | $0.005 / 1k, $0.0004 / 1k |
| Internet egress | $0.09 / GB (first 10 TB) |
| NAT Gateway data processed | $0.045 / GB |
| CloudWatch Logs ingestion | $0.50 / GB |
| API Gateway REST / HTTP | $3.50 / M, $1.00 / M |
| DynamoDB on-demand writes / reads | $0.625 / M WRU, $0.125 / M RRU |
| SES | $0.10 / 1k emails |

Example: an S3→Lambda loop at 1,000 concurrency, 1 PUT per invocation of 200 ms =
5,000 PUT/s ≈ $25/s in requests alone ≈ $2.1M/day if nothing stops it.

## Account checklist (console, not in code)

- [ ] Billing → **AWS Budgets** with alerts at several thresholds, plus a **Budget Action**
      that applies a deny policy for the riskiest services.
- [ ] **Cost Anomaly Detection** monitor with email or Slack alerts.
- [ ] Account-level Lambda concurrency limit: know the number, and request a lower quota for
      side projects if needed.
- [ ] S3 → **Block Public Access** at the account level unless public buckets are required.
- [ ] Check that the free-tier / free-plan status is what you expect. Set up a "Zero spend" budget.
- [ ] Turn on root-account MFA and remove unused access keys. Leaked keys are used for crypto mining.
