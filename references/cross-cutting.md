# Cross-cutting patterns (all stacks)

These patterns cause bills in third-party services (email, analytics, LLM APIs, maps) as well
as in the host. Check them in every audit.

## X-LOOP: Loops, retries, and recursion

- **X-LOOP-1: Unbounded loops.** `while (true)`, `for (;;)`, `while True:`, recursion with no
  depth limit, pagination loops that trust a `next` cursor from the API (a bug can return the
  same cursor forever). Check each has an exit and a max iteration count.
- **X-LOOP-2: Retries with no cap.** `retries: Infinity`, `forever: true`, `retry: true` with no
  max, custom `catch → call again`. Check for max attempts, exponential backoff, and jitter.
  Retrying a paid call on a 4xx error is always wrong.
- **X-LOOP-3: Webhook echo.** A webhook handler that calls the same API that sends the webhook
  (Stripe `customer.updated` → update customer; GitHub push → commit; Slack event → post message
  that fires an event). Check for an idempotency key, an event-source check, or a "no change" exit.
- **X-LOOP-4: Client-side request loops.** React `useEffect` with no deps or with an object
  dep that changes each render, which calls an API or analytics `capture`. Each open tab then
  sends requests in a loop. Multiply by active users.

## X-ABUSE: Public endpoints that spend money

- **X-ABUSE-1: Email and SMS sending.** Signup, password reset, magic link, invite, contact
  form, and "share" routes that call Mailgun, SendGrid, SES, Resend, Postmark, or Twilio. The
  $11k Mailgun incident and the $23k signup-spam incident both came from this. Each route
  needs a captcha (Turnstile, hCaptcha, reCAPTCHA) and a rate limit per IP and per target
  address. SMS is far more expensive (SMS pumping fraud): limit by country too.
- **X-ABUSE-2: Uploads.** Each upload route needs auth, a maximum size enforced on the server
  (not only in the UI), a content-type allowlist, and a per-user quota. Presigned URLs need
  a size condition and a short expiry.
- **X-ABUSE-3: LLM and AI APIs.** Routes that call OpenAI, Anthropic, Gemini, Workers AI,
  Bedrock, or Replicate. Check auth, a per-user rate limit, `max_tokens`/`max_output_tokens`,
  input length limits, a cap on agent/tool loop iterations, and a per-user or global daily
  budget. A public "chat" endpoint is an open proxy to a paid model.
- **X-ABUSE-4: Other usage-billed APIs.** Google Maps / Places (key with no HTTP-referrer or
  API restriction), geocoding, search APIs, transcription, image generation, PDF rendering.
- **X-ABUSE-5: Missing global protection.** If the scan finds no rate limiting and no captcha
  anywhere, and the app has any public write route, report it.

## X-HOT: Volume-based SaaS

- **X-HOT-1: Analytics and observability.** PostHog, Segment, Mixpanel, Amplitude, Sentry,
  Datadog, LogRocket. Two PostHog incidents ($1.3k after an AI-agent code change, $530 after
  months at $0). Look for `capture` in loops or render paths, `autocapture` on high-traffic
  pages, session recording at 100% sample, `tracesSampleRate: 1.0`, debug logs in production,
  and server-side events per request. Set billing limits in each tool.
- **X-HOT-2: High-frequency crons** that do heavy work (full scans, many API calls, many emails).
- **X-HOT-3: Hosted site builders** (Webflow, Framer, Mintlify). Bandwidth from large images
  and video is billed by plan overage. Check media sizes in exported assets if present.

## X-SECRET: Leaked keys

A leaked key turns into someone else's workload on your bill (crypto mining on AWS, LLM
resale on OpenAI/Anthropic keys).

- Secret keys in client-exposed env vars: `NEXT_PUBLIC_*`, `VITE_*`, `EXPO_PUBLIC_*`,
  `REACT_APP_*` that contain `SECRET`, `PRIVATE`, `SERVICE_ROLE`, or a server-only API key.
- Committed `.env` files, `serviceAccount*.json`, `credentials.json`.
- Known key shapes: `AKIA[0-9A-Z]{16}` (AWS), `sk_live_` (Stripe), `sk-` / `sk-ant-` (LLM),
  `AIza` (Google; often public by design, but it must have API restrictions).

Report the file and line, not the value. Tell the user to rotate the key. Note that removing
it from the latest commit does not remove it from git history.

## General account checklist (third-party services)

- [ ] Each usage-billed SaaS (email, SMS, analytics, LLM, maps) has a **hard billing limit**
      or a prepaid balance with auto-recharge off.
- [ ] LLM providers: set a monthly spend limit on the organization and per-project keys.
- [ ] Twilio: turn on geo permissions and SMS pumping protection.
- [ ] Google Maps keys: HTTP-referrer and API restrictions, plus per-day quotas.
- [ ] One person receives all billing alerts, and alerts go to a channel that someone reads
      on weekends.
