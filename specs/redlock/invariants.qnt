// Redlock 可執行規格：不變量階段（ADR-018）
//
// 本檔只描述「規格書要求什麼」。每一條 `val INV_*` 的內容都逐字引用
// `source.md`（redis.io Redlock 規格在本 repo 的固定存檔），並以 `// source:`
// 註解標明出處。`val WIT_*` 是同一條不變量所防範的危險狀態，供模型階段
// 證明危險狀態確實可達，避免「不變量成立但其實什麼都沒測到」的假綠燈。
//
// 本檔的狀態詞彙（型別、變數名稱與簽章）取自 `src/index.ts` 的公開介面
// （clients、resources、value、expiration、quorum、membershipSize 等），
// 但**不變量本身不取自程式碼**——照實作寫的不變量會把實作的缺陷一起當成
// 「正確」。本檔不修改 `src/`，也不定義任何動作或初始狀態：那是 model.qnt
// 的職責。
//
// 語意備註（審查重點）：
// - `isValidLock(c, r)` 讀作「c 目前持有一把尚未過期的鎖（r）」。
//   `held` 表示 acquire/extend 成功且尚未 release；規格假設 client 只在
//   `expiration` 之前使用該鎖。
// - `issuedAt` 對應規格的 T2（取得最後一個回覆的時間）；`expiration` 對應
//   「initial validity time minus the time elapsed」（規格步驟 4）。
// - 時間是單一邏輯時鐘 `now`（毫秒）。規範中的跨 process 時鐘漂移／牆鐘跳躍
//   無法用單一時鐘表達（見本 Issue 的未決事項）。

module invariants {

  // ---------------------------------------------------------------------
  // 模組參數（由 instances.qnt 的實例指定具體值）
  // ---------------------------------------------------------------------

  // Redis master 的數量。node-redlock 接受任意 >= 1 的節點數。
  const N: int

  // 可參與鎖定的 client 集合。
  const CLIENTS: Set[int]

  // 可被鎖定的資源集合（node-redlock 的 acquire 接受多個 resources）。
  const RESOURCES: Set[int]

  // ---------------------------------------------------------------------
  // 型別
  // ---------------------------------------------------------------------

  type ClientId = int
  type NodeId = int
  type ResourceId = int

  // 單一 Redis 實例上、單一資源的 key。
  // token == 0 表示 key 不存在；否則 token 是簽署這把鎖的隨機值。
  type KeyEntry = {
    token: int,
    expiration: int,
  }

  // 這把鎖最近一次是由哪個操作取得。
  type LockOp = Acquire | Extend

  // 單一 client 對單一資源的鎖定視圖。
  type LockView = {
    token: int,                 // 0 表示目前沒有鎖
    held: bool,                 // acquire / extend 成功且尚未 release
    issuedAt: int,              // 鎖被交出的時間（規格的 T2）
    expiration: int,            // client 認定的有效期截止時間
    acquiredNodes: Set[NodeId], // 這次嘗試中投下「for」的實例
    lastOp: LockOp,             // Acquire 或 Extend
  }

  // 單一 (client, 資源) 目前嘗試的 quorum 計票。
  type Quorum = {
    votesFor: int,
    votesAgainst: int,
    pending: bool, // 尚未達成 quorum，acquire 的 promise 尚未 resolve
  }

  // ---------------------------------------------------------------------
  // 狀態變數（抽象詞彙；由 model.qnt 賦予初始值與轉移）
  // ---------------------------------------------------------------------

  // 邏輯時鐘，單位毫秒。規格假設各 process 的本地時鐘以近似相同速率前進。
  var now: int

  // node -> resource -> 該實例上儲存的 key。
  var keyStore: NodeId -> (ResourceId -> KeyEntry)

  // client -> resource -> client 端的鎖定視圖。
  var lockView: ClientId -> (ResourceId -> LockView)

  // client -> resource -> 目前嘗試的計票。
  var quorum: ClientId -> (ResourceId -> Quorum)

  // 每個 Redis 實例是否可用（崩潰／網路分割時為 false）。
  var nodeUp: NodeId -> bool

  // ---------------------------------------------------------------------
  // 詞彙輔助
  // ---------------------------------------------------------------------

  pure val NODES: Set[NodeId] = 1.to(N)

  pure def majority(n: int): int = n / 2 + 1

  def lockOf(c: ClientId, r: ResourceId): LockView = lockView.get(c).get(r)

  def keyOf(n: NodeId, r: ResourceId): KeyEntry = keyStore.get(n).get(r)

  // client 目前是否持有一把尚未過期的鎖。
  def isValidLock(c: ClientId, r: ResourceId): bool = {
    val lv = lockOf(c, r)
    lv.held and lv.expiration > now
  }

  // 實例 n 上是否還存著 client c 針對資源 r 的有效 key。
  def ownsKeyOn(c: ClientId, r: ResourceId, n: NodeId): bool = {
    val lv = lockOf(c, r)
    val k = keyOf(n, r)
    lv.token != 0 and k.token == lv.token and k.expiration > now
  }

  // =====================================================================
  // 不變量
  // =====================================================================

  // source: source.md §Safety and Liveness Guarantees
  // 「Safety property: Mutual exclusion. At any given moment, only one client can hold a lock.」
  // 「During the time that the majority of keys are set, another client will not be able to acquire the lock, since N/2+1 SET NX operations can’t succeed if N/2+1 keys already exist. So if a lock was acquired, it is not possible to re-acquire it at the same time (violating the mutual exclusion property).」§Safety Arguments
  val INV_mutualExclusion: bool =
    RESOURCES.forall(r => CLIENTS.filter(c => isValidLock(c, r)).size() <= 1)

  // 危險狀態：同一個資源同時有兩個（含）以上的 client 持有未過期的鎖。
  val WIT_mutualExclusionViolation: bool =
    RESOURCES.exists(r => CLIENTS.filter(c => isValidLock(c, r)).size() >= 2)

  // source: source.md §The Redlock Algorithm step 3
  // 「If and only if the client was able to acquire the lock in the majority of the instances (at least 3), and the total time elapsed to acquire the lock is less than lock validity time, the lock is considered to be acquired.」
  val INV_acquireRequiresMajority: bool =
    CLIENTS.forall(c =>
      RESOURCES.forall(r => {
        val lv = lockOf(c, r)
        lv.held implies lv.acquiredNodes.size() >= majority(N)
      })
    )

  // 危險狀態：client 認為自己取得鎖，但投下「for」的實例數未達多數。
  val WIT_acquiredWithoutMajority: bool =
    CLIENTS.exists(c =>
      RESOURCES.exists(r => {
        val lv = lockOf(c, r)
        lv.held and lv.acquiredNodes.size() < majority(N)
      })
    )

  // source: source.md §The Redlock Algorithm step 4
  // 「If the lock was acquired, its validity time is considered to be the initial validity time minus the time elapsed, as computed in step 3.」
  // 「At this point we need to better specify our mutual exclusion rule: it is guaranteed only as long as the client holding the lock terminates its work within the lock validity time (as obtained in step 3), minus some time (just a few milliseconds in order to compensate for clock drift between processes).」§Is the Algorithm Asynchronous?
  // 「If a client locked the majority of instances using a time near, or greater, than the lock maximum validity time (the TTL we use for SET basically), it will consider the lock invalid and will unlock the instances」§Safety Arguments
  val INV_neverHandsOutExpiredLock: bool =
    CLIENTS.forall(c =>
      RESOURCES.forall(r => {
        val lv = lockOf(c, r)
        not(lv.held and lv.expiration <= lv.issuedAt)
      })
    )

  // 危險狀態：交出的鎖其有效期在交出的當下就已經耗盡（expiration <= issuedAt）。
  val WIT_expiredLockHandedOut: bool =
    CLIENTS.exists(c =>
      RESOURCES.exists(r => {
        val lv = lockOf(c, r)
        lv.held and lv.expiration <= lv.issuedAt
      })
    )

  // source: source.md §Correct Implementation with a Single Instance
  // 「This value must be unique across all clients and all lock requests.」
  val INV_lockValueUniqueness: bool =
    CLIENTS.forall(c1 =>
      CLIENTS.forall(c2 =>
        RESOURCES.forall(r => {
          val t1 = lockOf(c1, r).token
          val t2 = lockOf(c2, r).token
          (c1 != c2 and t1 != 0 and t2 != 0) implies t1 != t2
        })
      )
    )

  // 危險狀態：兩個不同的 client 對同一資源使用了相同的隨機值。
  val WIT_lockValueCollision: bool =
    CLIENTS.exists(c1 =>
      CLIENTS.exists(c2 =>
        RESOURCES.exists(r => {
          val t1 = lockOf(c1, r).token
          val t2 = lockOf(c2, r).token
          c1 != c2 and t1 != 0 and t2 != 0 and t1 == t2
        })
      )
    )

  // source: source.md §Correct Implementation with a Single Instance
  // 「every lock is "signed" with a random string, so the lock will be removed only if it is still the one that was set by the client trying to remove it.」
  // 「Releasing the lock is simple, and can be performed whether or not the client believes it was able to successfully lock a given instance.」§Releasing the Lock
  val INV_heldLockBackedByOwnKeys: bool =
    CLIENTS.forall(c =>
      RESOURCES.forall(r => {
        val lv = lockOf(c, r)
        (lv.held and lv.expiration > now) implies
          lv.acquiredNodes.forall(n => ownsKeyOn(c, r, n))
      })
    )

  // 危險狀態：client 仍持有未過期的鎖，但它取得鎖的某個實例上已不存在屬於它的 key
  // （例如被別的 client 的 release 誤刪）。
  val WIT_lockKeyStolen: bool =
    CLIENTS.exists(c =>
      RESOURCES.exists(r => {
        val lv = lockOf(c, r)
        lv.held and lv.expiration > now and
          lv.acquiredNodes.exists(n => not(ownsKeyOn(c, r, n)))
      })
    )

  // source: source.md §Making the algorithm more reliable: Extending the lock
  // 「The client should only consider the lock re-acquired if it was able to extend」
  // 「the lock into the majority of instances, and within the validity time」
  // 「if the key exists and its value is still the random value the client assigned」
  val INV_extendRequiresMajorityWithinValidity: bool =
    CLIENTS.forall(c =>
      RESOURCES.forall(r => {
        val lv = lockOf(c, r)
        (lv.held and lv.lastOp == Extend) implies
          (lv.acquiredNodes.size() >= majority(N) and lv.expiration > lv.issuedAt)
      })
    )

  // 危險狀態：client 透過 extend 重新取得鎖，但未達多數，或已超出有效期。
  val WIT_extendedWithoutMajorityOrValidity: bool =
    CLIENTS.exists(c =>
      RESOURCES.exists(r => {
        val lv = lockOf(c, r)
        lv.held and lv.lastOp == Extend and
          (lv.acquiredNodes.size() < majority(N) or lv.expiration <= lv.issuedAt)
      })
    )

  // source: source.md §Safety and Liveness Guarantees
  // 「Liveness property A: Deadlock free. Eventually it is always possible to acquire a lock, even if the client that locked a resource crashes or gets partitioned.」
  // 「Liveness property B: Fault tolerance. As long as the majority of Redis nodes are up, clients are able to acquire and release locks.」
  val INV_quorumSettles: bool =
    CLIENTS.forall(c =>
      RESOURCES.forall(r => {
        val q = quorum.get(c).get(r)
        (q.pending and q.votesFor + q.votesAgainst == N) implies
          (q.votesFor >= majority(N) or q.votesAgainst >= majority(N))
      })
    )

  // 危險狀態：所有實例的票都回來了，卻兩邊都未達多數——acquire 的 promise
  // 永遠不會 resolve（偶數節點平票造成永久 pending）。
  val WIT_tie: bool =
    CLIENTS.exists(c =>
      RESOURCES.exists(r => {
        val q = quorum.get(c).get(r)
        q.pending and q.votesFor + q.votesAgainst == N and
          q.votesFor < majority(N) and q.votesAgainst < majority(N)
      })
    )
}
