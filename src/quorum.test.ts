import test, { ExecutionContext } from "ava";
import { Redis as Client } from "ioredis";
import Redlock, { ExecutionError } from "./index.js";

// A stub client that never touches a real Redis server. `evalsha` (and `eval`
// as a fallback) resolve to a fixed, caller-controlled result, which lets tests
// produce deterministic votes: a result equal to the number of requested
// resources counts as a vote in favor, anything else as a vote against.
function createStubClient(result: number): Client {
  return {
    evalsha: async () => result,
    eval: async () => result,
  } as unknown as Client;
}

// Run an acquire attempt with a hard local deadline so a regression that leaves
// the operation permanently pending fails fast instead of hanging the suite.
async function acquireWithin(
  t: ExecutionContext<unknown>,
  redlock: Redlock,
  timeoutMs: number
): Promise<ExecutionError> {
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(
      () => reject(new Error(`acquire did not settle within ${timeoutMs}ms`)),
      timeoutMs
    );
  });

  try {
    const error = await t.throwsAsync<ExecutionError>(
      () => Promise.race([redlock.acquire(["resource"], 1000), timeout]),
      { instanceOf: ExecutionError }
    );
    if (!error) {
      throw new Error("expected acquire to reject with an ExecutionError");
    }
    return error;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

test.skip("acquire fails when 2 clients split their votes 1-1", async (t) => {
  const redlock = new Redlock([createStubClient(1), createStubClient(0)], {
    retryCount: 0,
    retryDelay: 0,
    retryJitter: 0,
  });

  const error = await acquireWithin(t, redlock, 2000);

  t.is(error.attempts.length, 1);
  const stats = await error.attempts[0];
  t.is(stats.membershipSize, 2);
  t.is(stats.quorumSize, 2);
  t.is(stats.votesFor.size, 1);
  t.is(stats.votesAgainst.size, 1);
});

test.skip("acquire fails when 4 clients split their votes 2-2", async (t) => {
  const redlock = new Redlock(
    [
      createStubClient(1),
      createStubClient(1),
      createStubClient(0),
      createStubClient(0),
    ],
    {
      retryCount: 0,
      retryDelay: 0,
      retryJitter: 0,
    }
  );

  const error = await acquireWithin(t, redlock, 2000);

  t.is(error.attempts.length, 1);
  const stats = await error.attempts[0];
  t.is(stats.membershipSize, 4);
  t.is(stats.quorumSize, 3);
  t.is(stats.votesFor.size, 2);
  t.is(stats.votesAgainst.size, 2);
});

test("acquire still succeeds with an odd number of clients and a majority", async (t) => {
  const redlock = new Redlock(
    [createStubClient(1), createStubClient(1), createStubClient(0)],
    {
      retryCount: 0,
      retryDelay: 0,
      retryJitter: 0,
    }
  );

  const lock = await redlock.acquire(["resource"], 1000);
  t.truthy(lock);
  t.is(lock.resources.length, 1);

  const { attempts } = await lock.release();
  const stats = await attempts[0];
  t.is(stats.votesFor.size, 2);
  t.is(stats.votesAgainst.size, 1);
});
