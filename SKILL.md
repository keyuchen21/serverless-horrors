---
name: serverless-horrors
description: This skill should be used when the user asks to "audit a repo for surprise bills", "check for serverless horrors", "find runaway cost risks", "check for infinite loops that cost money", "review my Cloudflare/Vercel/Firebase/AWS setup for billing risk", "can this repo get a huge bill", "denial-of-wallet review", or mentions serverlesshorrors.com, bill shock, spend caps, or budget alerts. Scans code and IaC for the patterns behind real five- and six-figure serverless bills (recursive triggers, Durable Object/queue loops, per-request expensive operations, open uploads/signups, unbounded egress, missing concurrency and spend guardrails) and writes a findings report.
version: 0.1.0
---

# Serverless Cost Audit

Audit a repository for **denial-of-wallet** risk: code or config that can turn a normal
bill into a five- or six-figure bill. The patterns come from real incidents on
https://serverlesshorrors.com (for example a Durable Object alarm loop at $10.8k, a queue
loop at $36k, Firebase + Cloud Run recursion at $72k, DDoS bandwidth at $104k–$120k,
and signup spam that triggered mass email at $11k–$23k).

The output is a **report only**. Do not edit project files. Fixes go in the report as
recommendations.

## Core principle

A cost incident needs three things together:

1. **A multiplier.** Something that repeats with no bound: a loop, a recursive trigger,
   retries, anonymous traffic, a bot, or an attacker.
2. **A metered unit.** Each repeat costs money: a write, a read, a request, a GB of
   egress, an email, an LLM token, or CPU time.
3. **No ceiling.** No max-instances, no rate limit, no retry cap, no hard spend cap.

Rate each finding on all three. A metered call inside a bounded admin-only job is low
risk. The same call inside a self-scheduling alarm is critical.

## Workflow

### Step 1: Detect the stack

Run the scanner. It detects providers, then lists candidate lines for each risk pattern.
`<skill-dir>` is the base directory of this skill (shown when the skill loads):

```bash
bash <skill-dir>/scripts/scan.sh <repo-root> > /tmp/cost-scan.txt
```

Read the `## Stack` section first. Then load **only** the reference files for the
detected providers:

| Detected | Load |
|---|---|
| `wrangler.toml` / `wrangler.json(c)`, `@cloudflare/*`, `DurableObject` | `references/cloudflare.md` |
| `vercel.json`, `next.config.*`, `next` dependency | `references/vercel-nextjs.md` |
| `firebase.json`, `*.rules`, `firebase-functions`, `@google-cloud/*`, Cloud Run | `references/firebase-gcp.md` |
| `serverless.yml`, `template.yaml` (SAM), CDK, Terraform `aws_*`, `@aws-sdk/*` | `references/aws.md` |
| Always | `references/cross-cutting.md` |

When the repo is a monorepo, run the scan on the root and note which package each hit
belongs to.

### Step 2: Triage the scan output

The scanner output is **candidates, not findings**. Most hits are benign. For each
candidate block:

1. Open the file around the hit with Read.
2. Follow the call chain until the three questions above have an answer:
   - What triggers this code, and who can trigger it (anonymous user, signed-in user,
     cron, internal event)?
   - What does each run cost, and how many runs can one trigger cause?
   - What stops it (guard condition, cap, rate limit, auth)?
3. Discard the hit if a clear ceiling exists. Keep a short note of discarded categories
   for the "Checked, no issue" section of the report.

Also read the `GUARD` checks. A `NOT FOUND` result there (for example no rate limiting,
no max-instances, no budget resource) is a finding by itself if the matching risk
exists.

### Step 3: Search past the scanner

Regex cannot see some patterns. Check these by reading code:

- **Recursive triggers.** For each event handler (storage trigger, DB trigger, queue
  consumer, webhook, DO alarm), list what it writes. If it writes to the source that
  triggers it, check that a guard stops the second run. See the "Loop patterns" section
  in each provider reference.
- **Self-calls.** A function that calls its own URL, its own service binding, or an API
  whose webhook calls it back (for example Stripe update → webhook → Stripe update).
- **Hot-path cost.** Middleware and per-request code that lists keys, scans tables,
  runs unbatched writes in a loop, or calls a paid API with no cache.
- **Fan-out.** One request that creates N jobs, N emails, or N LLM calls where N comes
  from user input.
- **Public large assets.** Video, images, model weights, or downloads served from
  metered storage or functions with no CDN cache.
- **AI-written code.** Two incidents came from AI-generated code (a Durable Object
  alarm loop and a Devin change that raised PostHog event volume). Give extra attention
  to loop exits and retry logic in recently generated code.

### Step 4: Estimate the worst case

For each kept finding, write one line of arithmetic:

```
rate × unit price × duration = worst case
e.g. 1 alarm/ms re-schedule ≈ 1,000 writes/s × $1.00/M writes × 86,400 s ≈ $86/day per object
```

Use the approximate unit prices in the provider reference. Mark the prices as
approximate. If the user needs exact numbers, fetch the provider's current pricing page.

### Step 5: Rate severity

| Severity | Rule |
|---|---|
| **Critical** | Has an unbounded multiplier and no ceiling, and anonymous traffic can start it or it can start itself (loop/recursion). |
| **High** | Unbounded multiplier, but a signed-in user, a deploy, or an operator mistake must start it. Or a ceiling exists but it is far above an acceptable bill. |
| **Medium** | Bounded, but the bound is high or depends on the provider (for example only default concurrency limits). Missing alerts or budgets when the risk exists. |
| **Low** | Inefficiency that raises the normal bill but cannot run away. |

### Step 6: Write the report

Use the template in `references/report-template.md`. Write it to
`cost-audit-report.md` in the repo root, unless the user names a different path. The
report must contain:

1. A summary table of findings, with the most severe first.
2. Each finding: severity, `file:line`, the three-part chain (multiplier → metered unit →
   missing ceiling), the worst-case estimate, and a concrete fix.
3. The **account checklist** for each detected provider (from the references). Code
   cannot show these settings, so the user must check them in the dashboard.
4. "Checked, no issue": the categories reviewed and cleared, so the user knows the
   coverage.

Then give the user a short summary in chat: the number of findings by severity, the top
three risks, and the path to the report.

## Rules

- Do not change project files. Do not run deploys, `terraform apply`, or provider CLIs
  that change state. Read-only commands (`wrangler whoami`, `gcloud config list`) are
  allowed only if the user agrees.
- Do not put secrets into the report. If a secret is found, give the file, line, and key
  type only, and say that the key must be rotated.
- Every finding must point to a real `file:line` that was read. Do not report a regex
  hit that was not checked.
- If a pattern was not checked (for example the IaC lives in another repo), say so in
  the report. Do not imply coverage that did not occur.

## Additional resources

### Reference files

- **`references/cloudflare.md`**: Workers, Durable Objects, KV, Queues, R2, cron. Loop
  patterns, guardrails, prices, account checklist.
- **`references/vercel-nextjs.md`**: Bandwidth, image optimization, middleware, ISR and
  dynamic rendering, function duration, firewall, Spend Management.
- **`references/firebase-gcp.md`**: Security rules, trigger recursion, max instances,
  BigQuery bytes billed, App Check, budgets that only alert.
- **`references/aws.md`**: Lambda recursion, S3 and public buckets, SQS retries, API
  Gateway throttling, NAT and log costs, Budgets and Budget Actions.
- **`references/cross-cutting.md`**: Email, uploads, LLM APIs, analytics, retries,
  leaked keys, webhooks. These apply to every stack.
- **`references/report-template.md`**: The report format.

### Scripts

- **`scripts/scan.sh <root>`**: Detects the stack and lists candidate lines per risk
  ID (`CF-*`, `NX-*`, `FB-*`, `AWS-*`, `X-*`). Requires `rg`. Read-only. Secret
  values are masked in the output. Do not open the file to read the full value.
- **`tests/run.sh`**: Runs the scanner on `tests/fixtures/` and checks the expected
  results. Run it after any change to `scan.sh`.
