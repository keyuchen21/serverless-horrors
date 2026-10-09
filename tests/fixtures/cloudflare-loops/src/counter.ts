import { DurableObject } from "cloudflare:workers";

// Bad: alarm re-schedules itself at once, with no exit condition.
export class Counter extends DurableObject {
  async alarm() {
    await this.ctx.storage.put("last", Date.now());
    await this.ctx.storage.setAlarm(Date.now());
  }
}
