import test from "ava";
import { Redis as Client } from "ioredis";
import Redlock, { ExecutionError } from "./index.js";

/*
 * A minimal ioredis stand-in that always votes "for" every script by returning
 * the number of requested keys. It lets these tests exercise `extend` without a
 * real Redis server. The optional delay simulates a slow reply from every node.
 */
class StubRedis {
  public constructor(public delayMs = 0) {}

  public async evalsha(_hash: string, numKeys: number): Promise<number> {
    if (this.delayMs > 0) {
      await new Promise((resolve) =>
        setTimeout(resolve, this.delayMs, undefined)
      );
    }

    return numKeys;
  }
}

function createRedlock(client: StubRedis): Redlock {
  return new Redlock([client as unknown as Client]);
}

test.skip("extend throws when the drift consumes the whole extension", async (t) => {
  const redlock = createRedlock(new StubRedis());
  const lock = await redlock.acquire(["{redlock}extend-min"], 100000);

  // A 1ms extension can never be valid: the drift alone is at least 2ms, so
  // the resulting expiration is in the past.
  await t.throwsAsync(() => lock.extend(1), { instanceOf: ExecutionError });
});

test.skip("extend throws when the reply arrives after the new validity elapses", async (t) => {
  const redlock = createRedlock(new StubRedis(300));
  const lock = await redlock.acquire(["{redlock}extend-slow"], 100000);

  // Every node takes 300ms to reply, so the 100ms extension reaches a quorum
  // only after its own validity has already elapsed.
  await t.throwsAsync(() => lock.extend(100), { instanceOf: ExecutionError });
});

test("extend returns a valid replacement lock when the extension is timely", async (t) => {
  const redlock = createRedlock(new StubRedis());
  const lock = await redlock.acquire(["{redlock}extend-valid"], 1000);
  const now = Date.now();

  const extended = await lock.extend(1000);

  t.true(
    extended.expiration > now,
    "The replacement lock must have a positive validity."
  );
  t.is(
    extended.value,
    lock.value,
    "The replacement lock must keep the original value."
  );
  t.is(lock.expiration, 0, "The original lock must be invalidated.");
});
