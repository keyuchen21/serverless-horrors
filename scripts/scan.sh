#!/usr/bin/env bash
# scan.sh: list candidate cost-risk lines in a repo. Read-only.
# Output is candidates for review, not findings. Risk IDs match references/*.md.
# Secret values are masked: the output shows file:line and the first 4 characters only.
# Usage: scan.sh [--strict] [repo-root] [max-lines-per-check]
#   --strict  exit 2 when a guard is NOT FOUND or a secret is found (for CI).

STRICT=0
if [ "${1:-}" = "--strict" ]; then
  STRICT=1
  shift
fi
ROOT="${1:-.}"
MAX="${2:-40}"
ISSUES=0
LAST_HITS=0

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) is required" >&2
  exit 1
fi
if [ ! -d "$ROOT" ]; then
  echo "error: not a directory: $ROOT" >&2
  exit 1
fi

RG=(rg --line-number --no-heading --color never --max-columns 220 --max-columns-preview
  --glob '!node_modules' --glob '!.git' --glob '!dist' --glob '!build' --glob '!out'
  --glob '!.next' --glob '!.vercel' --glob '!.wrangler' --glob '!.firebase' --glob '!.serverless'
  --glob '!.aws-sam' --glob '!cdk.out' --glob '!.terraform' --glob '!coverage' --glob '!vendor'
  --glob '!.venv' --glob '!venv' --glob '!__pycache__' --glob '!*.lock' --glob '!package-lock.json'
  --glob '!pnpm-lock.yaml' --glob '!*.min.js' --glob '!*.map' --glob '!*.svg'
  --glob '!cost-audit-report.md')

CODE=(--glob '*.{js,jsx,ts,tsx,mjs,cjs,py,go,rb,java,kt,rs,php,cs}')
CONF=(--glob '*.{toml,json,jsonc,yaml,yml,tf,hcl}' --glob '*.rules')

# mask: keep "file:line:" and the first 4 characters of the match.
mask() { sed -E 's/^(.*:[0-9]+:)(.{4}).*$/\1\2**** (masked)/'; }

# check [--mask] ID DESCRIPTION REGEX [extra rg args...]: print matching lines, if any.
# Sets LAST_HITS to the number of matching lines.
check() {
  local masked=0
  if [ "$1" = "--mask" ]; then
    masked=1
    shift
  fi
  local id="$1" desc="$2" re="$3"
  shift 3
  local out n
  LAST_HITS=0
  out=$("${RG[@]}" "$@" -e "$re" -- "$ROOT" 2>/dev/null)
  [ -z "$out" ] && return 0
  [ "$masked" = 1 ] && out=$(printf '%s\n' "$out" | mask)
  n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  LAST_HITS=$n
  printf '\n### [%s] %s (%s hits)\n' "$id" "$desc" "$n"
  printf '%s\n' "$out" | head -n "$MAX"
  [ "$n" -gt "$MAX" ] && printf '... (%s more)\n' "$((n - MAX))"
  return 0
}

# guard ID DESCRIPTION REGEX [extra rg args...]: like check, but print NOT FOUND when absent.
guard() {
  local id="$1" desc="$2" re="$3"
  shift 3
  if "${RG[@]}" -q "$@" -e "$re" -- "$ROOT" 2>/dev/null; then
    check "$id" "$desc" "$re" "$@"
  else
    printf '\n### [%s] %s: NOT FOUND\n' "$id" "$desc"
    ISSUES=$((ISSUES + 1))
  fi
}

has_file() { "${RG[@]}" --files "$@" -- "$ROOT" 2>/dev/null | head -n 1 | grep -q .; }
has_text() { "${RG[@]}" -q "$@" -- "$ROOT" 2>/dev/null; }

CF=0; NX=0; FB=0; AWS=0

echo "# Serverless cost scan: $ROOT"
echo "Candidates only. Read each hit before reporting it."

echo
echo "## Stack"
if has_file --glob 'wrangler.{toml,json,jsonc}' || has_text "${CODE[@]}" -e 'extends DurableObject|from .cloudflare:workers.|@cloudflare/workers-types'; then
  CF=1; echo "- Cloudflare: yes -> references/cloudflare.md"
fi
if has_file --glob 'vercel.json' --glob 'next.config.*' || has_text --glob 'package.json' -e '"next":'; then
  NX=1; echo "- Vercel / Next.js: yes -> references/vercel-nextjs.md"
fi
if has_file --glob 'firebase.json' --glob '*.rules' --glob 'database.rules.json' \
  || has_text --glob 'package.json' --glob 'requirements*.txt' --glob 'pyproject.toml' -e 'firebase|@google-cloud/|google-cloud-' \
  || has_text "${CONF[@]}" -e 'google_cloud_run|google_cloudfunctions|run\.googleapis\.com'; then
  FB=1; echo "- Firebase / GCP: yes -> references/firebase-gcp.md"
fi
if has_file --glob 'serverless.{yml,yaml}' --glob 'template.{yml,yaml}' --glob 'cdk.json' --glob 'samconfig.toml' \
  || has_text --glob 'package.json' --glob 'requirements*.txt' --glob 'pyproject.toml' -e '@aws-sdk/|aws-cdk|boto3' \
  || has_text --glob '*.tf' -e 'provider "aws"|resource "aws_'; then
  AWS=1; echo "- AWS: yes -> references/aws.md"
fi
echo "- Cross-cutting: always -> references/cross-cutting.md"

echo
echo "### Provider config files"
"${RG[@]}" --files --glob 'wrangler.{toml,json,jsonc}' --glob 'vercel.json' --glob 'next.config.*' \
  --glob 'netlify.toml' --glob 'firebase.json' --glob '*.rules' --glob 'serverless.{yml,yaml}' \
  --glob 'template.{yml,yaml}' --glob 'cdk.json' --glob '*.tf' --glob 'middleware.{ts,js}' \
  -- "$ROOT" 2>/dev/null | head -n "$MAX"

if [ "$CF" = 1 ]; then
  echo
  echo "## Cloudflare"
  check CF-LOOP-1 "DO alarm scheduling (check alarm() re-schedules with exit + min interval)" 'setAlarm\(|async alarm\(' "${CODE[@]}"
  check CF-LOOP-2 "DO stub calls (check A->B->A cycles)" '\.(idFromName|idFromString|newUniqueId|getByName)\(' "${CODE[@]}"
  check CF-LOOP-3 "Queue sends (compare with consumer queue names)" 'env\.[A-Za-z_0-9]+\.send(Batch)?\(' "${CODE[@]}"
  check CF-LOOP-4 "fetch() calls in Workers (check self-calls)" 'fetch\(\s*(request\.url|new URL\(|`https?://|["'"'"']https?://)' "${CODE[@]}"
  check CF-HOT-1 "KV / storage list() (expensive; check request path)" '\.(list)\(\s*(\{|\))' "${CODE[@]}"
  check CF-HOT-2 "DO storage / SQL writes (check inside loops)" 'storage\.(put|delete)\(|\.sql\.exec\(' "${CODE[@]}"
  check CF-HOT-3 "KV writes" 'env\.[A-Za-z_0-9]+\.put\(' "${CODE[@]}"
  check CF-CONF-1 "Wrangler cron / queue / limit settings" '^\s*(crons|max_retries|dead_letter_queue|retry_delay|max_batch_size|max_concurrency|cpu_ms|queue)\s*=|"(crons|max_retries|dead_letter_queue|cpu_ms)"' --glob 'wrangler.{toml,json,jsonc}'
  guard CF-GUARD-1 "Queue dead letter queue" 'dead_letter_queue' --glob 'wrangler.{toml,json,jsonc}'
  guard CF-GUARD-2 "Worker CPU limit" 'cpu_ms' --glob 'wrangler.{toml,json,jsonc}'
  guard CF-GUARD-3 "Rate limiting binding" 'ratelimit|RATE_LIMIT|\.limit\(\s*\{' "${CODE[@]}" "${CONF[@]}"
fi

if [ "$NX" = 1 ]; then
  echo
  echo "## Vercel / Next.js"
  echo
  echo "### [NX-EGRESS-1] Files over 5 MB in public/ or static/"
  find "$ROOT" \( -name node_modules -o -name .git -o -name .next -o -name .vercel \) -prune -o \
    -type f \( -path '*/public/*' -o -path '*/static/*' \) -size +5M -exec ls -lh {} \; 2>/dev/null \
    | awk '{print $5, $NF}' | head -n "$MAX"
  check NX-EGRESS-2 "Image optimization host patterns (wildcards = open proxy)" "hostname:\s*['\"][^'\"]*\*|domains:\s*\[|remotePatterns|minimumCacheTTL|unoptimized" --glob 'next.config.*'
  check NX-HOT-1 "Dynamic rendering / no cache" "dynamic\s*=\s*['\"]force-dynamic|revalidate\s*=\s*0\b|cache:\s*['\"]no-store|unstable_noStore|getServerSideProps" "${CODE[@]}"
  check NX-HOT-3 "Dynamic sitemap / robots / OG image routes" '' --glob '**/{sitemap,robots,opengraph-image,twitter-image}.{ts,tsx,js}' --glob '**/api/**/{sitemap,og}*.{ts,js}' --max-count 1
  check NX-HOT-4 "Short ISR revalidate (1-30 s)" 'revalidate\s*[:=]\s*([1-9]|[12][0-9]|30)\b' "${CODE[@]}"
  check NX-HOT-5 "maxDuration settings" 'maxDuration' "${CODE[@]}" --glob 'vercel.json'
  echo
  echo "### [NX-HOT-2] middleware files without config.matcher"
  "${RG[@]}" --files --glob 'middleware.{ts,js}' --glob 'proxy.{ts,js}' -- "$ROOT" 2>/dev/null | while read -r f; do
    grep -qE 'matcher[[:space:]]*:' "$f" || echo "$f: no matcher (runs on every request, including assets)"
  done
  check NX-ABUSE-1 "Server Actions (public POST endpoints; check auth + rate limit)" "^\s*['\"]use server['\"]" "${CODE[@]}"
fi

if [ "$FB" = 1 ]; then
  echo
  echo "## Firebase / GCP"
  check FB-ABUSE-1 "Security rules allow lines (check for if true / auth-only writes / no size limit)" 'allow\s' --glob '*.rules'
  check FB-ABUSE-1b "Realtime DB rules set to true" '"\.(read|write)"\s*:\s*(true|"true")' --glob 'database.rules.json' --glob '*.rules.json'
  check FB-LOOP-1 "Event triggers (check each writes outside its own source)" 'onObjectFinalized|onObjectMetadataUpdated|\.onFinalize\(|onDocument(Written|Created|Updated|Deleted)|onValue(Written|Created|Updated)|\.onWrite\(|\.onUpdate\(|\.onCreate\(|onMessagePublished|functions\.(storage|firestore|database|pubsub)' "${CODE[@]}"
  check FB-LOOP-3 "Event function retries" 'retry:\s*true|failurePolicy|retry_policy|RETRY_POLICY_RETRY' "${CODE[@]}" "${CONF[@]}"
  check FB-HOT-1 "Firestore listeners (check collection size)" 'onSnapshot\(' "${CODE[@]}"
  check GCP-HOT-1 "BigQuery queries (check bytes scanned, SELECT *)" 'createQueryJob|\.query\(\s*\{|client\.query\(|bigquery|SELECT\s+\*' -i "${CODE[@]}"
  guard FB-GUARD-1 "Max instances (Functions / Cloud Run)" 'maxInstances|max-instances|max_instances|maxScale|max_instance_count' "${CODE[@]}" "${CONF[@]}" --glob 'Dockerfile' --glob '*.sh'
  guard FB-GUARD-2 "App Check" 'initializeAppCheck|enforceAppCheck|appCheck' "${CODE[@]}"
  guard FB-GUARD-3 "BigQuery byte limit" 'maximumBytesBilled|maximum_bytes_billed' "${CODE[@]}" "${CONF[@]}"
  guard FB-GUARD-4 "Budget resource in IaC" 'google_billing_budget|billingbudgets' "${CONF[@]}" "${CODE[@]}"
fi

if [ "$AWS" = 1 ]; then
  echo
  echo "## AWS"
  check AWS-LOOP-1 "S3 event triggers (compare bucket + prefix with buckets the function writes)" 's3:ObjectCreated|S3EventSource|addEventNotification|aws_s3_bucket_notification|Type:\s*S3\b|^\s*-\s*s3:' "${CODE[@]}" "${CONF[@]}"
  check AWS-LOOP-1b "S3 writes in code" 'PutObjectCommand|CopyObjectCommand|\.putObject\(|put_object\(|upload_file\(|upload_fileobj\(|new Upload\(' "${CODE[@]}"
  check AWS-LOOP-2 "SQS / SNS / EventBridge publishes (check self-publish)" 'SendMessage(Batch)?Command|PublishCommand|PutEventsCommand|send_message\(|\.publish\(|put_events\(' "${CODE[@]}"
  check AWS-LOOP-3 "Retry / recursion settings" 'maxReceiveCount|max_receive_count|MaximumRetryAttempts|maximum_retry_attempts|retryAttempts|RecursiveLoop|recursive_loop|MaxAttempts' "${CODE[@]}" "${CONF[@]}"
  check AWS-ABUSE-1 "Public bucket settings" 'PublicRead|public-read|BLOCK_NONE|block_public_(acls|policy)\s*=\s*false|publicReadAccess:\s*true|"Principal"\s*:\s*"\*"' "${CODE[@]}" "${CONF[@]}"
  check AWS-ABUSE-2 "Presigned URLs (check size condition + expiry + auth)" 'getSignedUrl|createPresignedPost|generate_presigned_(url|post)|expiresIn' "${CODE[@]}"
  check AWS-ABUSE-3 "Function URLs with no auth" 'AuthType:\s*NONE|FunctionUrlAuthType\.NONE|authorization_type\s*=\s*"NONE"' "${CODE[@]}" "${CONF[@]}"
  check AWS-EGRESS-1 "NAT gateways" 'NatGateway|aws_nat_gateway|natGateways' "${CODE[@]}" "${CONF[@]}"
  check AWS-HOT-1 "DynamoDB scans" 'ScanCommand|\.scan\(|\.Scan\(' "${CODE[@]}"
  guard AWS-GUARD-1 "Lambda reserved concurrency" 'ReservedConcurrentExecutions|reservedConcurrentExecutions|reserved_concurrent_executions|reservedConcurrency' "${CODE[@]}" "${CONF[@]}"
  guard AWS-GUARD-2 "API Gateway throttling / usage plans / WAF" 'ThrottlingRateLimit|throttlingRateLimit|throttle|UsagePlan|usage_plan|aws_wafv2|WebACL' "${CODE[@]}" "${CONF[@]}"
  guard AWS-GUARD-3 "Budgets / anomaly detection in IaC" 'AWS::Budgets|aws_budgets_budget|CfnBudget|aws_ce_anomaly|AnomalyMonitor' "${CODE[@]}" "${CONF[@]}"
  guard AWS-GUARD-4 "Log retention" 'RetentionInDays|retention_in_days|logRetention|RetentionDays' "${CODE[@]}" "${CONF[@]}"
fi

echo
echo "## Cross-cutting"
check X-LOOP-1 "Unbounded loops" 'while\s*\(\s*(true|1)\s*\)|for\s*\(\s*;\s*;\s*\)|while\s+True\s*:|loop\s*\{' "${CODE[@]}"
check X-LOOP-2 "Uncapped retries" 'retries:\s*(Infinity|-1)|maxRetries:\s*(Infinity|-1)|forever:\s*true|retry:\s*(true|Infinity)|stop_never' "${CODE[@]}"
check X-LOOP-3 "Webhook handlers (check for echo loops)" 'webhook' -i --glob '*.{js,ts,mjs,py,go,rb}' --max-count 2
check X-LOOP-4 "useEffect with no dependency array (check for API/analytics calls inside)" 'useEffect\(\s*(async\s*)?\(\)\s*=>\s*\{[^}]*\}\s*\)\s*;?\s*$' "${CODE[@]}"
check X-ABUSE-1 "Email / SMS sending" 'resend\.emails\.send|sgMail\.send|mailgun|mg\.messages|SendEmailCommand|SendRawEmailCommand|send_email\(|nodemailer|postmark|twilio|messages\.create\(\s*\{\s*(to|from|body)' -i "${CODE[@]}"
check X-ABUSE-2 "Upload handling" 'multer|formidable|busboy|uploadBytes|createSignedUploadUrl|formData\(\)|UploadFile|request\.files' "${CODE[@]}"
check X-ABUSE-3 "LLM / AI API calls (check auth, rate limit, max_tokens)" 'chat\.completions\.create|messages\.create\(|responses\.create\(|generateText\(|streamText\(|generateObject\(|GoogleGenerativeAI|InvokeModel(WithResponseStream)?Command|env\.AI\.run\(|replicate\.run\(' "${CODE[@]}"
check X-ABUSE-4 "Maps / geo APIs" 'maps\.googleapis|@googlemaps|mapbox|places\.googleapis' -i "${CODE[@]}"
guard X-GUARD-1 "Rate limiting anywhere" 'ratelimit|rate-limit|rate_limit|rateLimit|Ratelimit|RateLimiter|slowapi|throttle' "${CODE[@]}" "${CONF[@]}"
guard X-GUARD-2 "Captcha / bot check anywhere" 'turnstile|recaptcha|hcaptcha|captcha|botid|checkBotId' -i "${CODE[@]}"
check X-HOT-1 "Analytics / observability volume settings" 'posthog\.capture|autocapture|session_recording|disable_session_recording|tracesSampleRate|replaysSessionSampleRate|profilesSampleRate|analytics\.track' "${CODE[@]}"
check X-HOT-2 "Scheduled jobs" 'crons\s*=|"crons"|schedule:\s*["'"'"']|onSchedule\(|pubsub\.schedule|rate\(\s*[0-9]+\s*minutes?\s*\)|cron\(' "${CODE[@]}" "${CONF[@]}"
check X-SECRET-1 "Secrets in client-exposed env vars (names only)" '(NEXT_PUBLIC|VITE|EXPO_PUBLIC|REACT_APP|PUBLIC)_[A-Z0-9_]*(SECRET|PRIVATE|SERVICE_ROLE|ADMIN|OPENAI|ANTHROPIC|STRIPE_SECRET)[A-Z0-9_]*' --hidden -o
ISSUES=$((ISSUES + LAST_HITS))
check --mask X-SECRET-2 "Known key shapes (values masked)" 'AKIA[0-9A-Z]{16}|sk_live_[0-9A-Za-z]{10,}|sk-ant-[0-9A-Za-z_-]{20,}|sk-(proj-)?[0-9A-Za-z_-]{32,}|-----BEGIN (RSA |EC )?PRIVATE KEY-----' --hidden -o
ISSUES=$((ISSUES + LAST_HITS))
echo
echo "### [X-SECRET-3] Committed env / credential files"
CRED_FILES=$("${RG[@]}" --files --hidden --glob '.env' --glob '.env.*' --glob '!.env.example' --glob '!.env.sample' --glob '!.env.template' \
  --glob '*serviceAccount*.json' --glob '*service-account*.json' --glob 'credentials.json' -- "$ROOT" 2>/dev/null)
if [ -n "$CRED_FILES" ]; then
  printf '%s\n' "$CRED_FILES" | head -n "$MAX"
  ISSUES=$((ISSUES + $(printf '%s\n' "$CRED_FILES" | wc -l)))
fi

echo
echo "## End of scan"
if [ "$STRICT" = 1 ] && [ "$ISSUES" -gt 0 ]; then
  echo "strict: $ISSUES issue(s): missing guards or secrets" >&2
  exit 2
fi
