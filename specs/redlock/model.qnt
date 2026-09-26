// Redlock 可執行規格：as-is 模型階段（ADR-018）
//
// 本檔依 `src/index.ts` 的**現況**建模（含缺陷），不修改 `src/`。
// 不變量定義於已核准的 `specs/redlock/invariants.qnt`；本檔 import 並 re-export，
// 讓 `instances.qnt` 的實例看得見 INV_*（少了 export 會 QNT404）。
//
// 來源對照（src/index.ts，本 repo 現況）：
//   ACQUIRE_SCRIPT : 12-27  對每個 key 先 exists 檢查，全部不存在才 set，回傳 key 數
//   EXTEND_SCRIPT  : 29-44  get(key)==value 才更新 TTL，否則回 0
//   RELEASE_SCRIPT : 46-58  get(key)==value 才刪除，回傳刪除數
//   acquire        : 297-341 duration 僅檢查整數；drift=round(driftFactor*duration)+2；
//                            quorum 成功即回傳 Lock，**未檢查取得所花時間 < validity**
//   release        : 350-364 先將 expiration 設 0，再對所有 node 執行 release script
//   extend         : 369-409 expiration < now 擋下；成功後 invalidate 舊 Lock 並回傳新 Lock
//   using          : 661-769 以 automaticExtensionThreshold 排程自動延長
//   _execute       : 416-471 對全部 client 重試，直到 quorum for 或嘗試耗盡
//   _attemptOperation          : 473-550 逐票累計；兩個方向都達 quorumSize 才 resolve
//   _attemptOperationOnClient  : 552-625 每個 client 回傳 for/against
//
// 抽象決定（詳見 docs/specs/redlock-model.md）：
//   - 單一邏輯時鐘 now；不建模時鐘漂移與牆鐘跳躍（Issue 範圍）。
//   - 跨資源原子性不在範圍：acquire/extend/release 逐資源建模，每個
//     (client, resource) 有獨立的嘗試狀態；程式在單一 node 上對多個 key 是原子的。
//   - node 崩潰/分割只改 nodeUp；重啟不遺失 key（Issue 範圍）。
//   - _execute 的重試回圈未逐一建模；一次嘗試失敗後可再發起新嘗試。
//   - using 的 routine 內容與 AbortSignal 為外部程式碼，抽象為 autoExtend 時序。

module model {
  import invariants.* from "./invariants"
  export invariants.*

  // ---------------------------------------------------------------------
  // 模型參數
  // ---------------------------------------------------------------------

  // 單次 acquire/extend 的 TTL（毫秒）。src/index.ts:302 只檢查整數，未限制最小值。
  const DURATION: int

  // using 的自動延長門檻（毫秒）。src/index.ts:700 要求
  // automaticExtensionThreshold <= duration - 100，否則 using 丟錯。
  const AUTO_EXTENSION_THRESHOLD: int

  // ---------------------------------------------------------------------
  // 模型專用型別（嘗試的生命週期）
  // ---------------------------------------------------------------------

  type AttemptKind = AttemptAcquire | AttemptExtend | AttemptRelease

  type Attempt = {
    active: bool,              // 嘗試進行中（promise 尚未 resolve）
    kind: AttemptKind,         // 目前執行的是哪個 script
    start: int,                // 這次嘗試的 T1（src/index.ts:481）
    token: int,                // 這次嘗試使用的 lock value
    voted: Set[NodeId],        // 已經回覆的 node
    forNodes: Set[NodeId],     // 投下 for 的 node
  }

  // ---------------------------------------------------------------------
  // 模型專用狀態變數（invariants.qnt 的狀態變數直接沿用）
  // ---------------------------------------------------------------------

  // 全域遞增的 lock value 來源，對應 src/index.ts:277-279 的 randomBytes。
  var nextToken: int

  // client -> resource -> 目前嘗試。
  var attempt: ClientId -> (ResourceId -> Attempt)

  // ---------------------------------------------------------------------
  // 詞彙輔助
  // ---------------------------------------------------------------------

  // 規格步驟 4 的 validity。src/index.ts:318-321：
  // drift = Math.round(driftFactor * duration) + 2，driftFactor 預設 0.01。
  // 以整數近似 round(0.01*duration) = (duration + 50) / 100。
  pure def driftFor(duration: int): int = (duration + 50) / 100 + 2

  pure val DRIFT: int = driftFor(DURATION)

  // 讓模擬能觀察到 key 過期；不變量本身與此界無關。
  pure val MAX_TIME: int = 5 * DURATION + 20

  pure val emptyKey: KeyEntry = { token: 0, expiration: 0 }

  pure val emptyLockView: LockView = {
    token: 0,
    held: false,
    issuedAt: 0,
    expiration: 0,
    acquiredNodes: Set(),
    lastOp: Acquire,
  }

  pure val emptyQuorum: Quorum = { votesFor: 0, votesAgainst: 0, pending: false }

  pure val emptyAttempt: Attempt = {
    active: false,
    kind: AttemptAcquire,
    start: 0,
    token: 0,
    voted: Set(),
    forNodes: Set(),
  }

  // Redis 的 key 是否仍然存在（lazy expire）。
  def keyLive(n: NodeId, r: ResourceId): bool =
    keyStore.get(n).get(r).token != 0 and keyStore.get(n).get(r).expiration > now

  // node n 上的 key 是否正是 token（extend / release script 的判斷）。
  def nodeOwnsKey(n: NodeId, r: ResourceId, tok: int): bool =
    keyLive(n, r) and keyStore.get(n).get(r).token == tok

  // 移除所有 node 上屬於 tok 的 key（只動可達的 node）。
  pure def removeToken(
    ks: NodeId -> (ResourceId -> KeyEntry),
    up: NodeId -> bool,
    r: ResourceId,
    tok: int
  ): NodeId -> (ResourceId -> KeyEntry) =
    NODES.fold(ks, (acc, n) =>
      if (up.get(n) and acc.get(n).get(r).token == tok)
        acc.put(n, acc.get(n).put(r, emptyKey))
      else acc)

  // ---------------------------------------------------------------------
  // 初始狀態
  // ---------------------------------------------------------------------

  action init: bool = all {
    now' = 0,
    keyStore' = NODES.mapBy(n => RESOURCES.mapBy(r => emptyKey)),
    lockView' = CLIENTS.mapBy(c => RESOURCES.mapBy(r => emptyLockView)),
    quorum' = CLIENTS.mapBy(c => RESOURCES.mapBy(r => emptyQuorum)),
    nodeUp' = NODES.mapBy(n => true),
    nextToken' = 1,
    attempt' = CLIENTS.mapBy(c => RESOURCES.mapBy(r => emptyAttempt)),
  }

  // ---------------------------------------------------------------------
  // 環境動作
  // ---------------------------------------------------------------------

  // 邏輯時鐘前進（模擬 RTT / 排程延遲）。
  action tick: bool = all {
    now < MAX_TIME,
    now' = now + 1,
    keyStore' = keyStore,
    lockView' = lockView,
    quorum' = quorum,
    nodeUp' = nodeUp,
    nextToken' = nextToken,
    attempt' = attempt,
  }

  // node 崩潰或網路分割。
  action crash(n: NodeId): bool = all {
    nodeUp.get(n),
    nodeUp' = nodeUp.put(n, false),
    now' = now,
    keyStore' = keyStore,
    lockView' = lockView,
    quorum' = quorum,
    nextToken' = nextToken,
    attempt' = attempt,
  }

  // node 重啟；規格前提是重啟不遺失 key。
  action recover(n: NodeId): bool = all {
    not(nodeUp.get(n)),
    nodeUp' = nodeUp.put(n, true),
    now' = now,
    keyStore' = keyStore,
    lockView' = lockView,
    quorum' = quorum,
    nextToken' = nextToken,
    attempt' = attempt,
  }

  // ---------------------------------------------------------------------
  // acquire（src/index.ts:297-341）
  // ---------------------------------------------------------------------

  action startAcquire(c: ClientId, r: ResourceId): bool = {
    val a = attempt.get(c).get(r)
    all {
      not(a.active),
      nextToken' = nextToken + 1,
      attempt' = attempt.put(c, attempt.get(c).put(r, {
        active: true,
        kind: AttemptAcquire,
        start: now,
        token: nextToken,
        voted: Set(),
        forNodes: Set(),
      })),
      quorum' = quorum.put(c, quorum.get(c).put(r, {
        votesFor: 0,
        votesAgainst: 0,
        pending: true,
      })),
      now' = now,
      keyStore' = keyStore,
      lockView' = lockView,
      nodeUp' = nodeUp,
    }
  }

  action voteAcquire(c: ClientId, r: ResourceId, n: NodeId): bool = {
    val a = attempt.get(c).get(r)
    val q = quorum.get(c).get(r)
    // ACQUIRE_SCRIPT：node 可用且 key 不存在 → for，並寫入 token/TTL。
    val isFor = nodeUp.get(n) and not(keyLive(n, r))
    val newFor = q.votesFor + (if (isFor) 1 else 0)
    val newAgainst = q.votesAgainst + (if (isFor) 0 else 1)
    val resolvedFor = newFor >= majority(N)
    val resolvedAgainst = newAgainst >= majority(N)
    val resolved = resolvedFor or resolvedAgainst
    val forNodes = if (isFor) a.forNodes.union(Set(n)) else a.forNodes
    val keyStoreAfterVote =
      if (isFor)
        keyStore.put(n, keyStore.get(n).put(r, { token: a.token, expiration: now + DURATION }))
      else keyStore
    // src/index.ts:330-340：acquire 失敗時 best-effort 清掉部分取得的 key。
    val finalKeyStore =
      if (resolvedAgainst) removeToken(keyStoreAfterVote, nodeUp, r, a.token)
      else keyStoreAfterVote
    val lockViewAfter =
      if (resolvedFor)
        lockView.put(c, lockView.get(c).put(r, {
          token: a.token,
          held: true,
          issuedAt: now,
          expiration: a.start + DURATION - DRIFT,
          acquiredNodes: forNodes,
          lastOp: Acquire,
        }))
      else lockView
    all {
      a.active,
      a.kind == AttemptAcquire,
      not(a.voted.contains(n)),
      keyStore' = finalKeyStore,
      lockView' = lockViewAfter,
      quorum' = quorum.put(c, quorum.get(c).put(r, {
        votesFor: newFor,
        votesAgainst: newAgainst,
        pending: q.pending and not(resolved),
      })),
      attempt' = attempt.put(c, attempt.get(c).put(r, {
        active: a.active and not(resolved),
        kind: a.kind,
        start: a.start,
        token: a.token,
        voted: a.voted.union(Set(n)),
        forNodes: forNodes,
      })),
      now' = now,
      nodeUp' = nodeUp,
      nextToken' = nextToken,
    }
  }

  // ---------------------------------------------------------------------
  // extend（src/index.ts:369-409）
  // ---------------------------------------------------------------------

  action startExtend(c: ClientId, r: ResourceId): bool = {
    val a = attempt.get(c).get(r)
    val lv = lockOf(c, r)
    all {
      not(a.active),
      lv.held,
      lv.expiration >= now,
      attempt' = attempt.put(c, attempt.get(c).put(r, {
        active: true,
        kind: AttemptExtend,
        start: now,
        token: lv.token,
        voted: Set(),
        forNodes: Set(),
      })),
      quorum' = quorum.put(c, quorum.get(c).put(r, {
        votesFor: 0,
        votesAgainst: 0,
        pending: true,
      })),
      now' = now,
      keyStore' = keyStore,
      lockView' = lockView,
      nodeUp' = nodeUp,
      nextToken' = nextToken,
    }
  }

  // using() 的自動延長：到期門檻內觸發（src/index.ts:716-721）。
  action autoExtend(c: ClientId, r: ResourceId): bool = {
    val a = attempt.get(c).get(r)
    val lv = lockOf(c, r)
    all {
      not(a.active),
      lv.held,
      lv.expiration >= now,
      lv.expiration - now <= AUTO_EXTENSION_THRESHOLD,
      attempt' = attempt.put(c, attempt.get(c).put(r, {
        active: true,
        kind: AttemptExtend,
        start: now,
        token: lv.token,
        voted: Set(),
        forNodes: Set(),
      })),
      quorum' = quorum.put(c, quorum.get(c).put(r, {
        votesFor: 0,
        votesAgainst: 0,
        pending: true,
      })),
      now' = now,
      keyStore' = keyStore,
      lockView' = lockView,
      nodeUp' = nodeUp,
      nextToken' = nextToken,
    }
  }

  action voteExtend(c: ClientId, r: ResourceId, n: NodeId): bool = {
    val a = attempt.get(c).get(r)
    val q = quorum.get(c).get(r)
    // EXTEND_SCRIPT：key 存在且 value 相符 → for，並更新 TTL。
    val isFor = nodeUp.get(n) and nodeOwnsKey(n, r, a.token)
    val newFor = q.votesFor + (if (isFor) 1 else 0)
    val newAgainst = q.votesAgainst + (if (isFor) 0 else 1)
    val resolvedFor = newFor >= majority(N)
    val resolvedAgainst = newAgainst >= majority(N)
    val resolved = resolvedFor or resolvedAgainst
    val forNodes = if (isFor) a.forNodes.union(Set(n)) else a.forNodes
    val keyStoreAfterVote =
      if (isFor)
        keyStore.put(n, keyStore.get(n).put(r, { token: a.token, expiration: now + DURATION }))
      else keyStore
    val lockViewAfter =
      if (resolvedFor)
        lockView.put(c, lockView.get(c).put(r, {
          token: a.token,
          held: true,
          issuedAt: now,
          expiration: a.start + DURATION - DRIFT,
          acquiredNodes: forNodes,
          lastOp: Extend,
        }))
      else lockView
    all {
      a.active,
      a.kind == AttemptExtend,
      not(a.voted.contains(n)),
      keyStore' = keyStoreAfterVote,
      lockView' = lockViewAfter,
      quorum' = quorum.put(c, quorum.get(c).put(r, {
        votesFor: newFor,
        votesAgainst: newAgainst,
        pending: q.pending and not(resolved),
      })),
      attempt' = attempt.put(c, attempt.get(c).put(r, {
        active: a.active and not(resolved),
        kind: a.kind,
        start: a.start,
        token: a.token,
        voted: a.voted.union(Set(n)),
        forNodes: forNodes,
      })),
      now' = now,
      nodeUp' = nodeUp,
      nextToken' = nextToken,
    }
  }

  // ---------------------------------------------------------------------
  // release（src/index.ts:350-364）
  // ---------------------------------------------------------------------

  action startRelease(c: ClientId, r: ResourceId): bool = {
    val a = attempt.get(c).get(r)
    val lv = lockOf(c, r)
    all {
      not(a.active),
      lv.held,
      // src/index.ts:354-355：呼叫當下立刻 invalidate 這把鎖。
      lockView' = lockView.put(c, lockView.get(c).put(r, { ...lv, held: false, expiration: 0 })),
      attempt' = attempt.put(c, attempt.get(c).put(r, {
        active: true,
        kind: AttemptRelease,
        start: now,
        token: lv.token,
        voted: Set(),
        forNodes: Set(),
      })),
      quorum' = quorum.put(c, quorum.get(c).put(r, {
        votesFor: 0,
        votesAgainst: 0,
        pending: true,
      })),
      now' = now,
      keyStore' = keyStore,
      nodeUp' = nodeUp,
      nextToken' = nextToken,
    }
  }

  action voteRelease(c: ClientId, r: ResourceId, n: NodeId): bool = {
    val a = attempt.get(c).get(r)
    val q = quorum.get(c).get(r)
    // RELEASE_SCRIPT：key 存在且 value 相符 → 刪除並計數。
    val isFor = nodeUp.get(n) and nodeOwnsKey(n, r, a.token)
    val newFor = q.votesFor + (if (isFor) 1 else 0)
    val newAgainst = q.votesAgainst + (if (isFor) 0 else 1)
    val resolvedFor = newFor >= majority(N)
    val resolvedAgainst = newAgainst >= majority(N)
    val resolved = resolvedFor or resolvedAgainst
    val forNodes = if (isFor) a.forNodes.union(Set(n)) else a.forNodes
    val keyStoreAfterVote =
      if (isFor)
        keyStore.put(n, keyStore.get(n).put(r, emptyKey))
      else keyStore
    all {
      a.active,
      a.kind == AttemptRelease,
      not(a.voted.contains(n)),
      keyStore' = keyStoreAfterVote,
      lockView' = lockView,
      quorum' = quorum.put(c, quorum.get(c).put(r, {
        votesFor: newFor,
        votesAgainst: newAgainst,
        pending: q.pending and not(resolved),
      })),
      attempt' = attempt.put(c, attempt.get(c).put(r, {
        active: a.active and not(resolved),
        kind: a.kind,
        start: a.start,
        token: a.token,
        voted: a.voted.union(Set(n)),
        forNodes: forNodes,
      })),
      now' = now,
      nodeUp' = nodeUp,
      nextToken' = nextToken,
    }
  }

  // ---------------------------------------------------------------------
  // 狀態機
  // ---------------------------------------------------------------------

  action step: bool = {
    nondet c = CLIENTS.oneOf()
    nondet r = RESOURCES.oneOf()
    nondet n = NODES.oneOf()
    any {
      tick,
      crash(n),
      recover(n),
      startAcquire(c, r),
      voteAcquire(c, r, n),
      startExtend(c, r),
      autoExtend(c, r),
      voteExtend(c, r, n),
      startRelease(c, r),
      voteRelease(c, r, n),
    }
  }

  // ---------------------------------------------------------------------
  // 情境 witness（正向描述不變量要保護的情境；不得在 init 成立）
  // ---------------------------------------------------------------------

  // 兩個 client 同時對同一資源持有（過或未過期的）鎖值。
  val WIT_twoClientsContend: bool =
    RESOURCES.exists(r =>
      CLIENTS.exists(c1 =>
        CLIENTS.exists(c2 =>
          c1 != c2 and
            lockOf(c1, r).token != 0 and
            lockOf(c2, r).token != 0)))

  // 某個 client 認為自己取得鎖，且 acquiredNodes 達到多數。
  val WIT_clientHoldsLock: bool =
    CLIENTS.exists(c =>
      RESOURCES.exists(r => {
        val lv = lockOf(c, r)
        lv.held and lv.acquiredNodes.size() >= majority(N)
      }))

  // 某個 client 持有一把尚未過期的鎖。
  val WIT_validLockHeld: bool =
    CLIENTS.exists(c =>
      RESOURCES.exists(r => {
        val lv = lockOf(c, r)
        lv.held and lv.expiration > now
      }))

  // 兩個 client 對同一資源持有不同的 lock value。
  val WIT_lockValuesDistinct: bool =
    RESOURCES.exists(r =>
      CLIENTS.exists(c1 =>
        CLIENTS.exists(c2 =>
          c1 != c2 and
            lockOf(c1, r).token != 0 and
            lockOf(c2, r).token != 0 and
            lockOf(c1, r).token != lockOf(c2, r).token)))

  // 某個 client 持有效鎖，且每個投 for 的 node 都還留著它的 key。
  val WIT_lockBackedByKeys: bool =
    CLIENTS.exists(c =>
      RESOURCES.exists(r => {
        val lv = lockOf(c, r)
        lv.held and lv.expiration > now and
          lv.acquiredNodes.forall(n => ownsKeyOn(c, r, n))
      }))

  // 某個 client 透過 extend 重新取得鎖，且達到多數並在有效期內。
  val WIT_extendSucceeded: bool =
    CLIENTS.exists(c =>
      RESOURCES.exists(r => {
        val lv = lockOf(c, r)
        lv.held and lv.lastOp == Extend and
          lv.acquiredNodes.size() >= majority(N) and
          lv.expiration > lv.issuedAt
      }))

  // 某次嘗試的所有 node 都已回覆（不論結果）。
  val WIT_allVotesReturned: bool =
    CLIENTS.exists(c =>
      RESOURCES.exists(r => {
        val q = quorum.get(c).get(r)
        q.votesFor + q.votesAgainst == N
      }))
}
