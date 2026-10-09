export { Counter } from "./counter";

export default {
  // Bad: the consumer sends every message back to the queue it reads.
  async queue(batch, env) {
    for (const msg of batch.messages) {
      await env.JOBS.send(msg.body);
    }
  },
};
