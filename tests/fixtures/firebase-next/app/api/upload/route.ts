import OpenAI from "openai";

const openai = new OpenAI();

// Bad: no auth, no size limit, no rate limit, and one LLM call per request.
export async function POST(req: Request) {
  const form = await req.formData();
  const text = String(form.get("text"));
  const res = await openai.chat.completions.create({
    model: "gpt-4o",
    messages: [{ role: "user", content: text }],
  });
  return Response.json(res);
}
