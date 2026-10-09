# serverless-horrors

A [Claude Code](https://claude.com/claude-code) skill that audits a repository for
**denial-of-wallet** risk: code or config that can turn a normal serverless bill into a
five- or six-figure bill.

The patterns come from real incidents collected on
[serverlesshorrors.com](https://serverlesshorrors.com). This project is not affiliated
with that site.

## Why

Most surprise bills do not come from high traffic. They come from one small mistake that
repeats with no limit:

| Incident | Cause | Bill |
|---|---|---|
| Durable Object alarm loop | `alarm()` re-schedules itself with no exit | ≈ $10.8k |
| Queue loop | Consumer sends messages back to its own queue | ≈ $36k |
| Firebase + Cloud Run | Trigger writes to the source that triggers it | ≈ $72k |
| DDoS on static assets | Metered bandwidth, no firewall, no spend cap | ≈ $104k–$120k |
| Signup spam | Each bot signup sends an email, no captcha | ≈ $11k–$23k |

Each one needs three things together:

1. **A multiplier**: a loop, a recursive trigger, retries, bots, or an attacker.
2. **A metered unit**: a write, a request, a GB of egress, an email, an LLM token.
3. **No ceiling**: no max-instances, no rate limit, no retry cap, no spend cap.

The skill looks for this chain and rates each finding by how easily it can start and
what stops it.

## Coverage

- **Cloudflare**: Workers, Durable Objects, KV, Queues, R2, cron
- **Vercel / Next.js**: bandwidth, image optimization, middleware, ISR, function duration
- **Firebase / Google Cloud**: security rules, trigger recursion, max instances, BigQuery
- **AWS**: Lambda recursion, S3, SQS, API Gateway, NAT, logs, CDK / SAM / Terraform
- **All stacks**: email and SMS, uploads, LLM APIs, analytics, retries, webhooks,
  leaked keys

## Install

```bash
git clone https://github.com/keyuchen21/serverless-horrors ~/.claude/skills/serverless-horrors
```

Requires [`ripgrep`](https://github.com/BurntSushi/ripgrep) (`rg`).

To update:

```bash
git -C ~/.claude/skills/serverless-horrors pull
```

## Use

In any project, ask Claude Code:

```
/serverless-horrors
```

or say "audit this repo for surprise bills" or "can this repo get a huge bill?".

Claude then:

1. Runs `scripts/scan.sh` to detect the stack and list candidate lines.
2. Reads each candidate and follows the call chain. Most candidates are cleared here.
3. Looks for patterns that regex cannot see: self-calls, fan-out, hot-path cost.
4. Estimates a worst case for each finding (`rate × unit price × time`).
5. Writes `cost-audit-report.md`: findings by severity with `file:line` and a fix, a
   dashboard checklist for each provider, and the list of checked areas.

The skill does not change project files, deploy, or run provider CLIs that change state.

## Scanner

The scanner also runs without Claude:

```bash
bash scripts/scan.sh /path/to/repo
```

Example output (from `tests/fixtures/cloudflare-loops`):

```
## Stack
- Cloudflare: yes -> references/cloudflare.md
- Cross-cutting: always -> references/cross-cutting.md

### [CF-LOOP-1] DO alarm scheduling (check alarm() re-schedules with exit + min interval) (2 hits)
./src/counter.ts:5:  async alarm() {
./src/counter.ts:7:    await this.ctx.storage.setAlarm(Date.now());

### [CF-LOOP-3] Queue sends (compare with consumer queue names) (1 hits)
./src/index.ts:7:      await env.JOBS.send(msg.body);

### [CF-GUARD-1] Queue dead letter queue: NOT FOUND
```

The output is a list of **candidates**, not findings. A hit means "read this line".
A `NOT FOUND` guard is a finding only when the matching risk exists. Secret values are
masked (`AKIA**** (masked)`).

## CI

`--strict` makes the scanner exit with code 2 when a guard is `NOT FOUND` or a secret is
found. Exit code 1 means an error (for example `rg` is missing).

```yaml
# .github/workflows/cost-scan.yml
name: cost-scan
on: pull_request
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/checkout@v4
        with:
          repository: keyuchen21/serverless-horrors
          path: .serverless-horrors
      - run: sudo apt-get install -y ripgrep
      - name: Scan
        shell: bash # enables pipefail, so the exit code of scan.sh is kept
        run: bash .serverless-horrors/scripts/scan.sh --strict . | tee cost-scan.txt
        continue-on-error: true
```

`--strict` is noisy: many small projects have no captcha or budget resource, and that
can be acceptable. Start with `continue-on-error: true` and treat the result as a
warning.

## Limits

- The scanner uses regex. It finds candidates, not proof. The Claude review step is what
  confirms or clears them.
- Account settings (spend caps, budgets, billing alerts) are not in code. The report
  gives a checklist for them, but it cannot check them.
- Unit prices in `references/` are approximate (as of 2026-10). Check the provider's
  pricing page for exact numbers.

## Test

```bash
bash tests/run.sh
```

Each folder in `tests/fixtures/` is a small project with known risks. Its `expect.txt`
lists the results the scanner must give. Run the tests after any change to `scan.sh`.

## Layout

```
SKILL.md              Audit workflow for Claude
references/           Patterns, prices, and checklists for each provider
scripts/scan.sh       Read-only scanner (stack detection and candidate lines)
tests/                Fixtures with known risks, and the test runner
```

## License

[MIT](LICENSE)
