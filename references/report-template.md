# Report template

Write the report to `cost-audit-report.md` in the repo root (or the path the user gives).
Keep it short. Each finding must have a real `file:line` that was read.

```markdown
# Serverless Cost Audit: <repo name>

Date: <YYYY-MM-DD> · Stack: <providers detected> · Scope: <paths scanned, anything excluded>

## Summary

| # | Severity | Risk ID | Finding | Location | Worst case |
|---|---|---|---|---|---|
| 1 | Critical | CF-LOOP-1 | DO alarm re-schedules every 1 ms with no exit | `src/room.ts:88` | ≈$860/day per object |
| 2 | High | X-ABUSE-1 | Signup sends email, no captcha or rate limit | `app/api/signup/route.ts:21` | ≈$1k per 1M bot signups |
| … | | | | | |

Totals: <n> critical, <n> high, <n> medium, <n> low.

## Findings

### 1. [Critical] <short title>

- **Location:** `path/to/file.ts:88` (also `wrangler.toml:14`)
- **Chain:**
  - Multiplier: <what repeats, and who or what starts it>
  - Metered unit: <what each repeat costs>
  - Missing ceiling: <what is not there: exit condition, cap, rate limit, auth>
- **Worst case:** `<rate> × <unit price> × <time> ≈ <amount>` (prices approximate)
- **Fix:** <concrete change, with a short code or config snippet if useful>

### 2. …

## Account checklist

Code cannot show these settings. Check each one in the provider dashboard.

### <Provider>
- [ ] <item from the provider reference>

## Checked, no issue

- <Risk ID / category>: <one line on why it is cleared, e.g. "queue consumer sends to a different queue (`wrangler.toml:30`)">

## Not covered

- <anything not checked, e.g. "Terraform for production lives in another repo">
```
