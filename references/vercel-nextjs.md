# Vercel / Next.js

Vercel appears in more serverlesshorrors incidents than any other provider. Most are
**bandwidth** (Fast Data Transfer): $96k, $46k, $23k (signup spam), $3k, $620 (a sitemap).
One incident reports that a $120 spend limit did not stop a $738 bill. Treat Spend
Management as a guardrail, not a guarantee.

## Egress patterns

### NX-EGRESS-1: Large files in `public/`

Every file in `public/` is served from Vercel's CDN and billed as data transfer. Videos,
large images, PDFs, zips, model files, and datasets in `public/` are the most common cause.

Check: list files over ~1 MB under `public/` (the scanner lists files over 5 MB). Estimate
`file size × expected downloads`. A 50 MB video watched 100k times = 5 TB.

Fix: move large media to a host with no or low egress fee (R2, Bunny, Mux, YouTube/Vimeo,
S3 + CloudFront with a budget). Compress images. Use `<video preload="none">`.

### NX-EGRESS-2: Open image optimization

```js
images: { remotePatterns: [{ protocol: 'https', hostname: '**' }] }
```

With a wildcard host, anyone can use `/_next/image?url=<any-url>&w=<any-width>` to make the
project fetch, transform, and serve any image. Each new source and width is a billed
transformation plus transfer. Also check `images.domains` with broad entries, a very low
`minimumCacheTTL`, and many `deviceSizes`/`imageSizes` (each one is a cache variant).

Fix: list exact hosts and paths. Limit `deviceSizes`. Set `minimumCacheTTL`. Use
`unoptimized` for images that are already small.

### NX-EGRESS-3: Large API or SSR responses

API routes that return big JSON, files streamed through a function (instead of a redirect
to storage), or pages with huge inlined `__NEXT_DATA__` / RSC payloads. Function responses
are billed as transfer and as function time.

## Hot-path patterns

- **NX-HOT-1: Dynamic rendering on high-traffic pages.** `export const dynamic = 'force-dynamic'`,
  `revalidate = 0`, `cache: 'no-store'`, `cookies()`/`headers()` in a root layout (this makes
  all pages dynamic), or `getServerSideProps` on the home page. Each view is a function call.
  Check if the page could be static or ISR.
- **NX-HOT-2: Middleware on all paths.** A `middleware.ts` with no `config.matcher`, or a
  matcher that includes `_next/static`, images, and fonts. Middleware then runs on every
  asset request. Exclude static paths.
- **NX-HOT-3: Dynamic sitemap / robots / OG images.** `app/sitemap.ts` or an API route that
  queries the DB on every crawler hit. Crawlers fetch these often. Make them static or cache
  them with `revalidate`.
- **NX-HOT-4: Very short ISR `revalidate`** (1–10 s) on many pages. Each revalidation is a
  function call and a cache write.
- **NX-HOT-5: Long `maxDuration`** (for example 300–800 s) on public routes that call slow
  APIs or stream LLM output. Duration is billed. Check that each long route needs it.

## Abuse patterns

- Signup, contact, and "invite" routes with no captcha or rate limit. The $23k EchoFox
  incident was 56k+ spam accounts. See `cross-cutting.md` for email and LLM fan-out.
- Server Actions are public POST endpoints. Check auth and rate limits in each action, not
  only in the UI.
- Preview deployments are public by default on some plans. Check Deployment Protection if
  previews hit paid APIs or production data.

## Guardrails to look for

| Guardrail | Where |
|---|---|
| `maxDuration` per route | `vercel.json` `functions`, or `export const maxDuration` |
| `config.matcher` | `middleware.ts` |
| Rate limiting | `@vercel/firewall` `checkRateLimit`, `@upstash/ratelimit`, or similar |
| Bot protection | `@vercel/firewall`, BotID, Turnstile, hCaptcha, reCAPTCHA |
| Exact `images.remotePatterns` | `next.config.*` |
| Cache headers | `vercel.json` `headers`, `next.config.*` `headers()` |

## Approximate unit prices (as of 2026-10; verify on the current pricing page)

| Unit | ≈ Price (Pro, after included amount) |
|---|---|
| Fast Data Transfer | $0.15 / GB (varies by region) |
| Edge / function requests | $0.60 / M |
| Image optimization | billed per transformation and cache read/write |
| Function active CPU / memory | per CPU-hour and GB-hour |

Example: 2 TB of video egress per day ≈ 2,000 GB × $0.15 = $300/day ≈ $9k/month.

## Account checklist (dashboard, not in code)

- [ ] Settings → Billing → **Spend Management**: set an amount and turn on **pause
      production deployments** when reached. Spend Management data can lag, so set the
      amount well below the maximum acceptable bill.
- [ ] Set usage notifications at 50% / 75% / 100%.
- [ ] Firewall → turn on bot protection. Know how to start **Attack Challenge Mode**
      quickly. Add rate-limit rules for `/api/*` and auth paths.
- [ ] Usage tab → check the top paths by data transfer every month.
- [ ] Deployment Protection on preview deployments if they use production secrets.
- [ ] On the Hobby plan, know that limits pause the project (no bill), but commercial use is
      not allowed.
