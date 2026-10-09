# Cloudflare (Workers, Durable Objects, KV, Queues, R2)

Cloudflare has **no hard spend cap** on Workers usage. Three of the most recent
serverlesshorrors incidents are Cloudflare loops ($10.8k, $8.8k, $36k). Treat every
self-scheduling or self-enqueuing path as critical until a guard is proven.

## Loop patterns

### CF-LOOP-1: Durable Object alarm that re-schedules itself

```ts
async alarm() {
  await this.doWork();
  await this.ctx.storage.setAlarm(Date.now() + 1);   // runs again in 1 ms, forever
}
```

Check:
- Does `alarm()` call `setAlarm` with no exit condition (state flag, counter, empty queue)?
- What is the minimum interval? `Date.now()` or `+ 0..100` ms is a hot loop.
- Does each run write storage? Each write is metered. Reads also cost money.
- Does an error path re-schedule too? Alarms retry with backoff on throw. A
  `try/finally { setAlarm(...) }` re-schedules on every failure.
- Does `fetch()` or a constructor call `setAlarm` unconditionally, so each request resets it?

Fix: exit when there is no work. Use a minimum interval (seconds, not ms). Keep a run
counter in storage and stop past a limit. Log and alert on high alarm rates.

### CF-LOOP-2: Two Durable Objects that call each other

Object A calls B, and B calls A back (directly or through a queue or alarm). Look for
`env.<NAMESPACE>.get(id)` followed by `stub.fetch()`/RPC in both classes. Find the stop
condition.

### CF-LOOP-3: Queue consumer that enqueues to its own queue

```ts
async queue(batch, env) {
  for (const msg of batch.messages) {
    await env.MY_QUEUE.send(next(msg.body));   // same queue as the consumer
  }
}
```

Check `wrangler.toml` for which queue the consumer reads (`[[queues.consumers]] queue = ...`)
and which binding the code sends to (`[[queues.producers]] binding = ...`). The same queue
name on both sides needs a depth or TTL field on the message that must reach zero.

Also check:
- `max_retries` (default 3) and `dead_letter_queue`. With no DLQ, a poison message retries
  and then is lost. With a DLQ that has a consumer that re-sends to the main queue, a loop exists.
- `retry_delay`. Zero delay and many retries amplify cost.
- A consumer that throws on the whole batch re-delivers all messages.

### CF-LOOP-4: Worker that fetches its own route

A Worker that calls `fetch()` on its own hostname, or a service binding to itself.
Cloudflare limits subrequest depth, but each hop is still billed, and fan-out
(N fetches per hop) grows fast.

### CF-LOOP-5: Cron at high frequency doing heavy work

`[triggers] crons = ["* * * * *"]` that does a KV `list()` or a full scan each minute.
Bounded, but it can be the largest line in the bill.

## Hot-path patterns

- **CF-HOT-1: KV `list()` per request.** `list` is billed like a write (≈$5/M) and is slow.
  The $36k incident had a KV list scan on every request. Cache the result or keep an index key.
- **CF-HOT-2: Unbatched DO storage writes.** `storage.put(k, v)` in a loop. Use
  `storage.put({ ... })` (up to 128 keys) or one SQL transaction. With SQLite-backed DOs,
  billing is per row written, so writes inside loops multiply directly.
- **CF-HOT-3: KV write per request.** KV writes are ≈$5/M and limited to 1 write/s per key.
  Counters in KV are a sign of a design problem. Use a DO or Analytics Engine.
- **CF-HOT-4: Workers AI / external LLM calls from public routes** with no rate limit. See
  `cross-cutting.md`.

## Egress and abuse

- R2 has no egress fee, but **Class A (writes/list) ≈$4.50/M and Class B (reads) ≈$0.36/M**
  operations are billed. A public bucket (`r2.dev` subdomain or custom domain) with no cache
  rules can be hit with millions of GETs.
- Public upload routes to R2 with no auth or size limit: storage grows, and Class A ops are billed.
- Cloudflare Images / Stream: billed per image stored, per transformation, and per minute
  delivered. Open transformation URLs (any width, any source) allow cache-busting abuse.
- Cloudflare enterprise-sales escalations happened on bandwidth-heavy sites on non-enterprise
  plans ($120k incident). Large video or file hosting on a Pro/Business plan is a policy risk too.

## Guardrails to look for

| Guardrail | Where |
|---|---|
| `[limits] cpu_ms = ...` | `wrangler.toml` (Standard usage model). Caps CPU per invocation. |
| `max_retries`, `dead_letter_queue`, `retry_delay`, `max_batch_size` | `[[queues.consumers]]` |
| Rate limiting binding (`[[unsafe.bindings]] type = "ratelimit"` or `[[ratelimits]]`) | `wrangler.toml` + `env.LIMITER.limit({ key })` in code |
| Turnstile on signup / upload / contact forms | frontend + server-side `siteverify` |
| WAF rate-limiting rules | dashboard only. Add to account checklist. |
| Loop exit and depth counters | code |

## Approximate unit prices (as of 2026-10; verify on the current pricing page)

| Unit | ≈ Price |
|---|---|
| Workers requests | $0.30 / M |
| Workers CPU | $0.02 / M CPU-ms |
| DO requests | $0.15 / M |
| DO duration | $12.50 / M GB-s |
| DO SQLite rows written | $1.00 / M |
| DO SQLite rows read | $0.001 / M |
| DO KV-backend reads / writes | $0.20 / M, $1.00 / M |
| KV reads | $0.50 / M |
| KV writes / list / delete | $5.00 / M |
| Queues operations | $0.40 / M (about 3 ops per 64 KB message: write, read, delete) |
| R2 Class A / Class B | $4.50 / M, $0.36 / M |

Example: an alarm loop that writes 10 rows each ms = 10,000 rows/s ≈ $0.01/s ≈ $864/day per
object. With 10 objects in the loop, that is ≈$8.6k/day.

## Account checklist (dashboard, not in code)

- [ ] Billing → set **usage-based billing notifications** for Workers, DO, KV, Queues, R2.
- [ ] Know that there is **no hard cap**. Decide on a kill switch: a script or a manual
      runbook that removes routes, deletes the queue consumer, or deploys a no-op Worker.
- [ ] WAF → rate-limiting rules on API, auth, and upload paths.
- [ ] Bot Fight Mode / Super Bot Fight Mode on public sites.
- [ ] R2 → disable the `r2.dev` public URL if not needed. Put a custom domain with cache rules in front.
- [ ] Workers analytics → check request and DO alarm rates after each deploy of loop-related code.
