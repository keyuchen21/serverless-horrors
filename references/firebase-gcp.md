# Firebase / Google Cloud

Google Cloud **budgets only send alerts. They do not stop spend.** Incidents: $100k in one day
(DoS on Firebase Storage uploads), $70k (Firebase/GCS storage), $72k (Firebase + Cloud Run
recursion in testing), $22k (BigQuery queries on a public dataset).

## Loop patterns

### FB-LOOP-1: Trigger writes to its own source

```ts
export const onImage = onObjectFinalized(async (event) => {
  const thumb = await resize(event.data);
  await bucket.file(`thumbs/${event.data.name}`).save(thumb);   // same bucket → triggers again
});

export const onUser = onDocumentWritten('users/{id}', async (event) => {
  await event.data.after.ref.update({ updatedAt: now() });       // writes the same doc → triggers again
});
```

Check every trigger: `onObjectFinalized`, `onDocumentWritten/Created/Updated`,
`onValueWritten` (Realtime DB), `onMessagePublished`, v1 `functions.storage.object().onFinalize`,
`functions.firestore.document().onWrite`, Eventarc triggers on Cloud Run.

For each one, list what it writes. If it writes to the source path, it needs one of:
- An early return when the object is already processed (path prefix check, metadata flag,
  or `before`/`after` field compare that ignores its own fields).
- A different output bucket or collection.

A field-compare guard must compare only the fields the user changes. A guard such as
"return if `before` equals `after`" fails when the function sets `updatedAt`.

### FB-LOOP-2: Pub/Sub or Cloud Tasks re-publish

A subscriber that publishes to its own topic, or a Cloud Task that enqueues itself with no
depth limit.

### FB-LOOP-3: Event retries

`retry: true` (v2 option) or "Retry on failure" on event functions retries for up to 7 days.
A function that always throws (bad input, missing permission) then runs for 7 days. Retry
only on transient errors and make the handler idempotent.

### FB-LOOP-4: Cloud Run / Functions that call themselves over HTTP

A service that calls its own URL, directly or through a scheduler or webhook. Check for
fan-out (each call starts N calls).

## Abuse patterns

### FB-ABUSE-1: Open security rules

```
allow read, write: if true;
allow write: if request.auth != null;          // any signed-up user (anonymous auth counts)
```

For Storage, also require size and type limits on write:

```
allow write: if request.auth != null
              && request.resource.size < 5 * 1024 * 1024
              && request.resource.contentType.matches('image/.*');
```

Check `storage.rules`, `firestore.rules`, `database.rules.json`. If Anonymous Auth is on,
`request.auth != null` gives no protection against bots.

### FB-ABUSE-2: Public downloads of large objects

Download URLs (`getDownloadURL`) are permanent and public. A large file shared on social media
or hot-linked can create large egress. Put Cloud CDN in front or use a host with low egress.

### FB-ABUSE-3: No App Check

Without App Check, any script can call Firestore, Storage, and callable functions with the
public config. Look for `initializeAppCheck` in the client and `enforceAppCheck: true` on
callable functions.

## Hot-path patterns

- **FB-HOT-1: Firestore listeners on large collections.** `onSnapshot` on a whole collection
  in the client. Each change sends reads to every listener. Each new listener reads all docs.
- **FB-HOT-2: Reads in loops / N+1.** `for (id of ids) await getDoc(...)`. Each doc is one read.
- **FB-HOT-3: Counters in one document.** Hot docs are limited to about 1 write/s and cause
  contention retries. Use distributed counters.
- **GCP-HOT-1: BigQuery with no byte limit.** On-demand queries are billed by bytes scanned.
  `SELECT *` on a large public dataset scans all columns. Look for `maximumBytesBilled` /
  `maximum_bytes_billed` on query jobs, `dryRun` checks, partition filters, and
  `require_partition_filter` on tables.

## Guardrails to look for

| Guardrail | Where |
|---|---|
| `maxInstances` | v2 `setGlobalOptions({ maxInstances })` or per function; v1 `runWith({ maxInstances })` |
| Cloud Run max instances | `--max-instances`, `autoscaling.knative.dev/maxScale`, Terraform `max_instance_count` |
| `timeoutSeconds`, `concurrency` | function options |
| `maximumBytesBilled` | BigQuery job config |
| BigQuery custom quotas | Console → Quotas → "Query usage per day" (per project / per user) |
| App Check | client `initializeAppCheck`, server `enforceAppCheck: true` |
| Size and type limits | `storage.rules` |
| Budget + kill switch | Terraform `google_billing_budget` + Pub/Sub function that disables billing |

Default max instances for Cloud Functions v2 and Cloud Run is 100 per function/service.
A loop at 100 instances still runs all day.

## Approximate unit prices (as of 2026-10; verify on the current pricing page)

| Unit | ≈ Price |
|---|---|
| Firestore reads / writes / deletes | $0.03–0.06 / 100k reads, $0.09–0.18 / 100k writes (by region) |
| Cloud Storage egress (internet) | $0.12 / GB (first TB, most regions) |
| Cloud Storage Class A / Class B ops | $0.005 / 1k, $0.0004 / 1k |
| BigQuery on-demand | $6.25 / TiB scanned |
| Cloud Functions / Run | per vCPU-s and GiB-s, plus requests ≈ $0.40 / M |

Example: an `onDocumentWritten` loop at 100 instances × 50 writes/s each = 5,000 writes/s
≈ 432M writes/day ≈ $780/day in writes, plus function invocation time.

## Account checklist (console, not in code)

- [ ] Billing → **Budgets & alerts** at several thresholds. Know that a budget does **not** cap.
- [ ] For a hard cap, connect the budget to Pub/Sub and a function that **disables billing**
      on the project (Google documents this pattern). Test it. Know that it can stop all services.
- [ ] Turn on App Check enforcement for Firestore, Storage, and Functions.
- [ ] BigQuery → set custom per-day query quotas.
- [ ] Turn off Anonymous Auth if not needed.
- [ ] Use separate projects for test and production. The $72k incident happened during testing.
