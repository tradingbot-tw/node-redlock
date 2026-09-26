import test from "ava";
import type { Redis as IORedisClient } from "ioredis";

import Redlock, { ExecutionError } from "./index.js";

type ScriptName = "acquire" | "release" | "extend";

interface ScriptCall {
  readonly script: ScriptName;
  readonly keys: string[];
  readonly args: (string | number)[];
}

interface StubClient {
  readonly calls: ScriptCall[];
  evalsha(
    hash: string,
    numkeys: number,
    args: (string | number)[]
  ): Promise<number>;
  eval(
    script: string,
    numkeys: number,
    args: (string | number)[]
  ): Promise<number>;
}

function identifyScript(script: string): ScriptName {
  if (script.startsWith("-- stub:acquire")) return "acquire";
  if (script.startsWith("-- stub:release")) return "release";
  if (script.startsWith("-- stub:extend")) return "extend";

  throw new Error(
    `Unrecognized script passed to the stub client: ${script.slice(0, 40)}`
  );
}

/**
 * Build a client stub that answers every script without contacting redis. The
 * acquire script votes "for" after an optional delay, which lets us simulate a
 * quorum reply that arrives after the requested lock duration has elapsed.
 */
function createStubClient({
  acquireDelay = 0,
}: { acquireDelay?: number } = {}): StubClient {
  const calls: ScriptCall[] = [];

  return {
    calls,
    async evalsha(): Promise<number> {
      // Force the redlock instance to fall back to `eval`, so the stub can see
      // the raw script text and identify which operation is attempted.
      throw new Error("NOSCRIPT stub client has no cached scripts");
    },
    async eval(
      script: string,
      numkeys: number,
      args: (string | number)[]
    ): Promise<number> {
      const scriptName = identifyScript(script);
      calls.push({
        script: scriptName,
        keys: args.slice(0, numkeys).map(String),
        args: args.slice(numkeys),
      });

      if (scriptName === "acquire" && acquireDelay > 0) {
        await new Promise((resolve) => setTimeout(resolve, acquireDelay));
      }

      // Every requested key is accepted/updated/removed.
      return numkeys;
    },
  };
}

// Wrap each script with a unique marker so the stub can tell them apart without
// reaching into redlock's private script constants.
const scripts = {
  acquireScript: (script: string): string => `-- stub:acquire\n${script}`,
  releaseScript: (script: string): string => `-- stub:release\n${script}`,
  extendScript: (script: string): string => `-- stub:extend\n${script}`,
};

function createRedlock(client: StubClient): Redlock {
  return new Redlock([client as unknown as IORedisClient], {}, scripts);
}

function releasesFor(client: StubClient, resource: string): ScriptCall[] {
  return client.calls.filter(
    (call) => call.script === "release" && call.keys.includes(resource)
  );
}

// A one-millisecond duration can never produce a positive remaining validity:
// the drift is always at least 2ms, so `start + duration - drift` is in the
// past by the time the quorum is reached.
test.skip("acquire rejects a lock whose validity has already elapsed (short duration)", async (t) => {
  const client = createStubClient();
  const redlock = createRedlock(client);

  await t.throwsAsync(redlock.acquire(["lock:short"], 1), {
    instanceOf: ExecutionError,
  });

  t.true(
    releasesFor(client, "lock:short").length > 0,
    "the key was not released after the expired lock was rejected"
  );
});

// Simulate a quorum reply that arrives after the lock duration has elapsed.
test.skip("acquire rejects a lock whose validity elapsed while awaiting the quorum", async (t) => {
  const client = createStubClient({ acquireDelay: 100 });
  const redlock = createRedlock(client);

  await t.throwsAsync(redlock.acquire(["lock:delayed"], 20), {
    instanceOf: ExecutionError,
  });

  t.true(
    releasesFor(client, "lock:delayed").length > 0,
    "the key was not released after the expired lock was rejected"
  );
});
