export default {
  async fetch(request, env) {
    const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
    const { success } = await env.RATE_LIMITER.limit({ key: ip });
    if (!success) return new Response("Too many requests", { status: 429 });

    const form = await request.formData();
    const ok = await verifyTurnstile(form.get("cf-turnstile-response"), env);
    if (!ok) return new Response("Bot check failed", { status: 403 });
    return new Response("ok");
  },
};

async function verifyTurnstile(token, env) {
  const res = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    method: "POST",
    body: new URLSearchParams({ secret: env.TURNSTILE_SECRET, response: token }),
  });
  return (await res.json()).success;
}
