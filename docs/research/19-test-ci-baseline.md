# node-redlock（tradingbot-tw fork）測試結構與 CI 現況基線

> **本文件是分析報告（`agent-analyze`），不具放行效力**（docs/06 §4：僅可產出分析與方案，不得實作）。
> 本次 run **未修改任何程式碼、測試、`ci.yml`、`docker-compose.yml` 或 README**；唯一變更是本文件。

## 0. 文件資訊（對應 REQ-1）

| 項目 | 值 | 出處 |
|---|---|---|
| 描述對象（分支） | `software-factory`（本工廠 trunk；GitHub 預設分支仍為 `main`） | `gh api repos/tradingbot-tw/node-redlock` → `default_branch = "main"`（實測於本 run，見附錄 A3） |
| 描述對象（commit SHA） | `8371226056b85ca70632e91ec9b0d5236336f41b`（分析時 `software-factory` 的 HEAD；即 `Merge pull request #17 from tradingbot-tw/factory/6-03-docs`） | `git rev-parse HEAD`、`git log -1`（附錄 A1） |
| 工作項 | Issue #19「盤點 node-redlock（tradingbot-tw）的測試結構與 CI 設定」，類型 `agent-analyze` | Issue #19 本體 |
| 分析日期 | 2026-10-13（UTC） | 本 run 時間戳 |
| 沙箱環境 | Node.js v22.21.1、Docker 28.0.4、**無 `node_modules`、無 `docker-compose`（v1）** | `node --version`、`docker --version`、`which docker-compose`（附錄 A2） |

本文件所有結論均附 `檔案:行號` 出處（REQ-5）；純外部事實（AVA 預設 timeout、上游檔案比對）另附來源 URL 或實測命令。

---

## 1. 結論摘要

1. **測試框架是 AVA 4，不是 Jest**，且測試是「**先編譯、再跑編譯產物**」：`yarn test` 實際執行
   `cd dist/esm && ava --verbose *.test.js`（`package.json:67`），檔來源是 `tsc` 把 `./src/**/*`
   編譯到 `./dist/esm`（`tsconfig.json:6`、`tsconfig.json:16`）。因此**沒跑 `yarn build` 就沒有任何測試可跑**
   （`dist/esm/` 在 repo 內只有 `package.json` 佔位檔，`dist/**/*.js` 被 gitignore：`.gitignore:3-5`）。
2. **測試分兩類**：需要外部 Redis 的整合測試（`src/single.test.ts`、`src/multi.test.ts`，共 24 個 AVA 案例）
   與**完全不需要 Redis** 的單元測試（`src/quorum.test.ts:9-14`、`src/acquire-expiration.test.ts:14`、
   `src/extend.test.ts`，共 8 個案例，用 stub client 模擬 `evalsha`/`eval`）。
   → 「不得在沒有 Redis 的環境執行測試」的 Issue 已知問題（Issue #19 本體）**只適用於前者**。
3. **Redis 主機名稱 7 個全部對應 `docker-compose.yml` 的 service 名稱**（REQ-4 對照表見 §2.3）；
   另有一個故意連不通的 `127.0.0.1`（`src/single.test.ts:205`）作為失敗路徑測試。
   `docker compose config --services` 實測解析出 **27 個 service，其中 23 個是 `redis-*`**（附錄 A4），
   與 `.github/factory/risk-paths.yml:18` 所載「23 個 redis 測試容器」一致。
4. **CI 的最大問題不在內容，而在「根本不會跑」**：`ci.yml` 只在 `push`/`pull_request` 且
   `branches: [main]` 時觸發（`.github/workflows/ci.yml:4-7`），而工廠的工作分支是 `software-factory`；
   本 fork 的 Actions 執行紀錄 `total_count = 0`（附錄 A3）。→ **既有的 #4/#5/#6 修正與本報告都以「未經此 CI 驗證」的狀態存在。**
5. **即使觸發，CI 也不可重現**：`yarn.lock` 被刻意 ignore（`.gitignore:10`），安裝步驟是裸 `yarn`
   （`docker-compose.yml:229`），相依全是 semver range（`package.json:48-61`）→ 每次 run 解析到的版本可能不同；
   且容器基鏡是 `node:16`（`docker-compose.yml:227`、`:244`、`:286`）。
6. **發現一個候選缺陷（未實測、需人類確認）**：單節點叢集的建立命令把 `10.0.0.14:6379` 寫了兩次、
   漏掉 `10.0.0.15:6379`（`docker-compose.yml:89`），而 `10.0.0.15` 確實是一個已定義的服務節點
   （`docker-compose.yml:67-76`）。這会让 `--cluster-replicas 1` 只拿到 5 個唯一節點，
   `redis-cli --cluster create` 有極高機率直接失敗；該 bootstrap service 又只是 `depends_on`
   （`docker-compose.yml:90-96`，compose 不等 service 成功結束、repo 內亦無 healthcheck），
   失敗不會讓 `docker compose run` 中止 → 測試端只會在 `waitForCluster()` 無限輪詢
   （`src/single.test.ts:43-48`）直到 AVA 的 10 秒 inactivity timeout 把整個 test file 打紅。
   **此檔與上游 `mike-marcacci/node-redlock@main` byte-identical**（附錄 A5）→ 是上游帶入的問題，不是 fork 造成的分歧。
7. **CI 的 lint/build/test 三步都走 dev watch 路徑的間接機制**：`builder`/`runner` service 的
   `entrypoint` 是 `./scripts/await.sh …`（`docker-compose.yml:246`、`:288`），CI 傳入的 `yarn lint`/`yarn build`/`yarn test`
   只覆蓋 `command`（`docker-compose.yml:247`、`:289` 與 `.github/workflows/ci.yml:22,24,26`），
   實際執行的是「等 `node_modules/.bin/tsc`、等 `node_modules/.bin/ava`、等 `dist/esm/index.js` 出現後才 eval 命令」
   （`scripts/await.sh:3-10`）。→ **步驟間存在隱性時序耦合**，任何一步產物沒落地，下一步就靜靜等待。
8. 本文件對 Issue 的 5 條驗證方式（REQ-1…REQ-5）**全數涵蓋**；對 DoD 第三項「跑測試確認綠燈」**未能涵蓋**
   （本沙箱無 `node_modules`、無 Redis、無 lockfile，實跑需先安裝依賴＝超出分析型範圍），
   詳見 §2.10 與 §5 工作項 W2。

---

## 2. 證據與根因

### 2.1 工具鏈與「測試怎麼跑」的實際路徑（REQ-2）

`package.json:62-71` 的 scripts 逐條（**實際執行的命令原字串**）：

| script | 行號 | 實際命令 | 說明 |
|---|---|---|---|
| `format` | `package.json:63` | `prettier --list-different --write '**/*.{json,yml,md,ts}'` | 寫入式格式化（會改檔） |
| `lint` | `package.json:64` | `prettier -c '**/*.{json,yml,md,ts}' && eslint src --ext ts` | 两段式：先 prettier **check**（唯讀），再 eslint 只掃 `src`、副檔名 `ts` |
| `build` | `package.json:65` | `rm -f dist/**/*.{js,js.map,d.ts} && tsc && tsc -p tsconfig.cjs.json` | 先清 dist，再雙重編譯（ESM→`dist/esm`，CJS→`dist/cjs`） |
| `build:development` | `package.json:66` | `rm -f dist/**/*.{js,js.map,d.ts} && tsc --watch` | watch 模式，**不產 CJS** |
| `test` | `package.json:67` | `cd dist/esm && ava --verbose *.test.js` | **CI 用的就是這一条**；只跑 ESM 產物 |
| `test:development` | `package.json:68` | `cd dist/esm && ava --verbose --watch *.test.js` | `runner` service 的預設命令（`docker-compose.yml:289`） |
| `prepare` | `package.json:69` | `yarn build` | `yarn install` 後自動觸發 ⇒ 容器內 `installer` 跑 `yarn`（`docker-compose.yml:229`）時已順帶 build |
| `prepublishOnly` | `package.json:70` | `yarn install && yarn lint && yarn build` | 發佈用；CI 未執行 |

其他相關事實：

- **AVA 設定**：`package.json:43-47` 只有 `nodeArguments: ["--experimental-specifier-resolution=node"]`；
  **未設定 `timeout`、`failFast`、`concurrency`**（同一區塊）。
- 套件本身是 ESM/CJS 雙輸出：`"type": "module"`（`package.json:75`）、`main`/`module`/`types`
  （`package.json:13-15`）、`exports`（`package.json:16-22`）；`dist/esm/package.json` 內容為 `{"type":"module"}`、
  `dist/cjs/package.json` 為 `{"type":"commonjs"}`（兩檔為 repo 內少數被 track 的 dist 檔，`git ls-files dist`）。
- `tsc` 把**測試檔一併編譯**：`include: ["./src/**/*"]`（`tsconfig.json:16`）且 `rootDir: "./src"`
  （`tsconfig.json:10`）→ `*.test.js` 落在 `dist/esm/`，正是 `yarn test` 的 glob 目標（`package.json:67`）。
- 執行期相依只有一個：`node-abort-controller ^3.0.1`（`package.json:72-74`）；
  `ioredis ^4.28.5` 是 **devDependency**（`package.json:57`），由使用者自行提供（README 未強制，`README.md:23`）。
- `engines.node >= 12`（`package.json:39-41`）、`browserslist: node >= 12`（`package.json:42`）
  → 與容器基鏡 `node:16`（`docker-compose.yml:227`）不同源，無任何測試涵蓋 Node 12/18/20/22 矩陣。

### 2.2 測試結構盤點（框架、案例分組、外部依賴）

`git ls-files src` 顯示 6 個檔案，其中 5 個是測試（附錄 A1）：

| 檔案 | AVA 案例數（編譯後實際跑出的數量） | 斷言呼叫數（原始碼字面計數） | 需要外部 Redis？ | 出處 |
|---|---|---|---|---|
| `src/single.test.ts` | 9 個定義 × 2 個 namespace = **18** | 60 | **是** | 定義於 `single.test.ts:80,98,138,202,248,281,336,422,465`；`run()` 於 `:548`、`:550` |
| `src/multi.test.ts` | 3 個定義 × 2 個 namespace = **6** | 38 | **是** | 定義於 `multi.test.ts:95,177,263`；`run()` 於 `:317-322`、`:324-329` |
| `src/quorum.test.ts` | **3** | 13 | 否（stub） | `quorum.test.ts:45,62,87`；stub 於 `:5-14` |
| `src/acquire-expiration.test.ts` | **2** | 2 | 否（stub） | `acquire-expiration.test.ts:98,113`；`StubClient` 型別於 `:14` |
| `src/extend.test.ts` | **3** | 3 | 否（stub） | `extend.test.ts:28,37,46` |
| 合計 | **32** 個 AVA 案例 | **116** | 24 需要 Redis / 8 不需要 | — |

> 口徑說明：斷言數為對 `t.is(`/`t.assert(`/`t.fail(`/`t.not(` 的**原始碼字面** grep 計數；
> `single.test.ts`/`multi.test.ts` 的案例經 `run(namespace, …)` 以兩個 namespace 各跑一次
> （`single.test.ts:67`、`:548`、`:550`），故「實際執行的斷言數」約為字面計數的兩倍（該兩檔）。
> 計數命令見附錄 A6。

**分組機制（同一份測試跑兩次拓撲）**：`run(namespace, …)` 把同一批案例以 `instance` 與 `cluster`
兩個 prefix 註冊兩次（`single.test.ts:548`、`:550`；`multi.test.ts:317-329`），
案例標題格式為 `${namespace} - <描述>`（例如 `single.test.ts:98`）。

**每個被測試的拓撲**（`redis-*` 均為 compose service，见 §2.3）：

| namespace | Redlock 客戶端組成 | 語意 | 出處 |
|---|---|---|---|
| `single`/`instance` | 1 個 standalone Redis | 「單一實例」的正確性基線（非 HA） | `single.test.ts:548`；對應註解 `docker-compose.yml:14` |
| `single`/`cluster` | 1 個 Redis Cluster（6 節點、3 主 3 從） | 單叢集 HA（README 明示「理論上可能拿到兩次鎖」`README.md:174-178`） | `single.test.ts:550`；`docker-compose.yml:27-99` |
| `multi`/`instance` | 3 個彼此獨立的 standalone | 真正的 Redlock 多數決 | `multi.test.ts:317-322`；`docker-compose.yml:19-24` |
| `multi`/`cluster` | 3 個彼此獨立的 Cluster（各 3 節點、無副本） | 多叢集（「probably excessive」） | `multi.test.ts:324-329`；`docker-compose.yml:101-223` |

**叢集類案例有兩道前置等待**（都在 `test.before`）：
`waitForCluster()` 輪詢 `cluster_state:ok`（`single.test.ts:34-48`）與可寫性 `SET isWritable`
（`single.test.ts:50-64`），`multi.test.ts:34-65` 是同一份邏輯的複製；第二個 `before` 對每個客戶端做
`keys("*") → del(...)` 全庫清空（`single.test.ts:74-78`、`multi.test.ts:87-93`）。
→ **測試彼此共用同一個 Redis 且會清空所有 key**，這也解釋了為何資源鍵一律帶 hash tag `{redlock}…`
（例如 `single.test.ts:105`、`multi.test.ts:102`；hash tag 的理由見 `README.md:182`）。

**被測行為（摘要，全部可回溯到行號）**：

- 非整數 duration 必丟出 `Duration must be an integer value in milliseconds.`（`single.test.ts:80-96`）。
- acquire→extend→release 的值與 TTL（`pttl` 以 200ms 分桶容差）：`single.test.ts:98-136`、多資源 `:138-200`。
- **連不到 Redis 時必須失敗，且 `attempts.length === 11`**（`single.test.ts:202-246`，斷言在 `:228-232`），
  錯誤訊息為 `Connection is closed.`（`:238`）。11 = `retryCount: 10`（`index.ts:108`）經 `retryCount + 1`
  換算而來的 `maxAttempts`（`index.ts:451-454`）。
- 鎖自動過期（duration 200ms、sleep 300ms）：`single.test.ts:248-279`。
- 互斥性（同資源、重疊資源）與 `ResourceLockedError` 型別檢查：`single.test.ts:281-334`、`:336-420`。
- `using()` 輔助方法與自動延長（`automaticExtensionThreshold: 200`）：`single.test.ts:422-463`、`:465-545`。
- 少數客戶端失敗仍成功 / 多數失敗必須失敗：`multi.test.ts:177-261`、`:263-314`（後者斷言
  `The operation was applied to: 0 of the 1 requested resources.`，`:300-303`）。
- 三個 stub 檔涵蓋：票數平分（2 客戶 1-1、4 客戶 2-2）不該 hang（`quorum.test.ts:45,62`）、
  奇數客戶多數決仍成功（`:87`）、acquire/extend 不得交出已過期鎖（`acquire-expiration.test.ts:98,113`、`extend.test.ts:28,37,46`）——
  對應 CHANGELOG 的 Unreleased 條目（`CHANGELOG.md:1-3`）與已合併的 #4/#5/#6。

**執行期對 Redis 的實際呼叫面**：Redlock 以 `client.evalsha(script.hash, keys.length, …)` 送 Lua，
失敗才退回 `client.eval(…)`（`src/index.ts:593-594`、`:615`）；stub client 正是攔截這兩個方法
（`quorum.test.ts:11-12`）→ 這是不需要 Redis 也能測的原因。

### 2.3 測試連線的 Redis 主機名稱 vs `docker-compose.yml` 服務名稱（REQ-4）

測試裡出現的**全部** `host:` 字面值（grep 實測，附錄 A4）與對照：

| 測試中的主機名稱 | 出自 | 客戶端型別 | `docker-compose.yml` service | service 定義行 | 備註 |
|---|---|---|---|---|---|
| `redis-single-instance` | `single.test.ts:548` | `Redis` | `redis-single-instance` | `:15-16` | `image: redis:6`，無 networks 設定→走 project default 網路 |
| `redis-single-cluster-1` | `single.test.ts:550` | `Cluster`（只給 1 個種子節點） | `redis-single-cluster-1` | `:27-36` | 靜態 IP `10.0.0.11`；同叢集另有 `.12`–`.16`（`:37-86`） |
| `redis-multi-instance-a` | `multi.test.ts:319` | `Redis` | `redis-multi-instance-a` | `:19-20` | 同 `b`（`:21-22`）、`c`（`:23-24`） |
| `redis-multi-instance-b` | `multi.test.ts:320` | `Redis` | `redis-multi-instance-b` | `:21-22` | 同上 |
| `redis-multi-instance-c` | `multi.test.ts:321` | `Redis` | `redis-multi-instance-c` | `:23-24` | 同上 |
| `redis-multi-cluster-a-1` | `multi.test.ts:326` | `Cluster` | `redis-multi-cluster-a-1` | `:102-111` | 種子節點；`a` 叢集另有 `.a-2`/`.a-3`（`:112-131`）與 bootstrap job `redis-multi-cluster-a`（`:132-141`） |
| `redis-multi-cluster-b-1` | `multi.test.ts:327` | `Cluster` | `redis-multi-cluster-b-1` | `:143-152` | bootstrap job `:173-182` |
| `redis-multi-cluster-c-1` | `multi.test.ts:328` | `Cluster` | `redis-multi-cluster-c-1` | `:184-193` | bootstrap job `:214-223` |
| `127.0.0.1` | `single.test.ts:204-211` | `Redis`（故意連不通） | **非 compose service（刻意）** | — | 失敗路徑測試；依赖 `runner` 容器本機沒有 6379（本沙箱實測「無本機 Redis」，附錄 A2） |

核對要點：

1. **7 個服務名稱 100% 對應**，沒有測試用到不存在的 service；Cluster 客戶端一律只給該叢集的 `-1` 節點當種子
   （`single.test.ts:550`、`multi.test.ts:326-328`），剩餘節點由叢集拓撲自行發現。
2. `redis-single-cluster`（`:87-99`）與 `redis-multi-cluster-a/b/c`（`:132`、`:173`、`:214`）**不是資料節點，
   而是一次性的 `redis-cli --cluster create` 初始化工具**；測試不會連它們（名稱未出現在 `host:`）。
3. `runner` 同時掛在 project default 與 `redis` 兩個網路（`docker-compose.yml:300-303`，靜態 IP `10.0.10.3`），
   這正是它既能解析 standalone 服務名（default 網）、又能解析叢集節點名（`redis` 網，`ipam` 區段 `:6-11`）的原因。
   `builder`/`installer` 不在 `redis` 網路（`:241-257`、`:226-238`）→ 只有 `runner` 有資格跑測試。
4. **所有 service 都是 `image: redis:6`**（例如 `:16`、`:20`、`:28`）；叢集節點另掛 `cluster.redis.conf`
   （bind mount `:30-33`）啟用 `cluster-enabled yes`、`appendonly yes`、`cluster-node-timeout 5000`
   （`cluster.redis.conf:1-5`）。**無持久化卷**、**無 healthcheck**（全檔無 `healthcheck:` 鍵）。
5. 實測：`docker compose config --services` 在本地就能成功解析（不需 daemon 連線執行），
   得到 **27 個 service / 23 個 `redis-*`**（附錄 A4），並對 `version: "3.7"`（`docker-compose.yml:1`）
   發出 `the attribute version is obsolete` 警告——compose v2 已不需要該欄位。

### 2.4 `ci.yml` 的觸發條件與每個步驟的實際命令（REQ-3）

檔全長 29 行（`.github/workflows/ci.yml`），job 只有一個：

| # | 步驟 | 行號 | 實際執行的命令 | `continue-on-error` |
|---|---|---|---|---|
| — | 觸發條件 `on.push.branches` | `:4-5` | `[main]` | — |
| — | 觸發條件 `on.pull_request.branches` | `:6-7` | `[main]` | — |
| — | `name` / `jobs.test.runs-on` | `:1`、`:10-12` | `Continuous Integration` / 單 job `Build & Test` @ `ubuntu-latest` | — |
| 1 | `actions/checkout@v2` | `:14` | （action，非 run） | 否 |
| 2 | `Enable docker layer cache` | `:15-17` | `satackey/action-docker-layer-caching@v0.0.11` | **true** |
| 3 | `Pull docker images` | `:18-20` | `docker-compose pull`（**帶連字號的 v1 命令**） | **true** |
| 4 | `Lint the source` | `:21-22` | `docker compose run --rm --no-TTY builder yarn lint` | 否 |
| 5 | `Transpile into dist` | `:23-24` | `docker compose run --rm --no-TTY builder yarn build` | 否 |
| 6 | `Run tests` | `:25-26` | `docker compose run --rm --no-TTY runner yarn test` | 否 |
| 7 | `Stop containers` | `:27-29` | `docker compose down`，`if: always()` | — |

逐步拆解（每步「實際上到底執行到什麼」）：

- **步驟 3**：`docker-compose pull`（`:19`）用 **v1 二進位**，而步驟 4–7 用 **v2 子命令**（`docker compose …`）。
  兩者混用；本沙箱實測 `docker-compose` **不存在**（`command not found`，附錄 A2）。
  因該步驟 `continue-on-error: true`（`:20`），**抓不到 image 也不會讓 CI 變紅**，只會在步驟 4
  由 `docker compose run` 自行 pull 而變慢。
- **步驟 4**：`docker compose run … builder yarn lint`。`builder` 的 `entrypoint` 是
  `./scripts/await.sh node_modules/.bin/tsc`（`docker-compose.yml:246`），CI 傳的 `yarn lint` 只取代 `command`
  （檔內預設 `command: yarn build:development`，`:247`）→ 真正執行的是
  `./scripts/await.sh node_modules/.bin/tsc yarn lint`，即「**先等 `node_modules/.bin/tsc` 出現，再 eval `yarn lint`**」
  （`scripts/await.sh:3-10`）。而 `depends_on: [installer]`（`:242-243`）使 `installer` 先跑 `yarn`
  （`:226-238`，`command: yarn`）安裝依賴——注意 `yarn install` 會觸發 `prepare: yarn build`（`package.json:69`），
  所以「lint 之前其實已經 build 過一次」。
- **步驟 5**：同結構跑 `yarn build`（`:24`）。
- **步驟 6**：`runner` 的 `entrypoint` 是巢狀 await：`./scripts/await.sh node_modules/.bin/ava ./scripts/await.sh dist/esm/index.js`
  （`docker-compose.yml:288`），加上 CI 傳入的 `yarn test`（`:26`）後展開為
  「等 `ava` 可執行檔 → 等 `dist/esm/index.js` → 執行 `yarn test`」。`runner` 的 `depends_on` 列出
  `builder` + **23 個 redis service**（`docker-compose.yml:260-285`）。
  `yarn test` 即 `cd dist/esm && ava --verbose *.test.js`（`package.json:67`）。
- **步驟 7**：`docker compose down` 帶 `if: always()`（`:27-29`），是唯一的清理保障；
  `--rm` 只作用在 `run` 出来的服務容器（`:22,24,26`），redis 容器需靠 `down` 回收。
- CI **沒有** `workflow_dispatch`、**沒有** `concurrency`、**沒有** 快取 yarn 目錄的步驟、
  **沒有** 覆蓋率/ artifacts 上傳步驟（整檔 `:1-29` 無此類鍵）。

**根因 R1（CI 對工廠工作項等於不存在）**：觸發條件只有 `main`（`:5`、`:7`），
而工廠 trunk 是 `software-factory`（本 run 的 `BASE_BRANCH`）。因此對 `software-factory` 的 PR
**既不屬於 `pull_request.branches` 的目標、push 也不是 `main`** → `ci.yml` 不會被觸發。
佐證：本 fork 的 Actions `runs?per_page=1` 回傳 `total_count = 0`，且 `actions/workflows` 列表回空
（附錄 A3；列表回空也可能出於 token 權限，需人類確認，見 §6-Q1）。
旁證：預設分支是 `main`（`gh api`），但已合併的工廠 PR #15–#17 的 base 皆為 `software-factory`（`gh pr list` 於附錄 A3）。

**根因 R2（不可重現的依賴解析）**：`yarn.lock` 在 `.gitignore:10`，`installer` 執行裸 `yarn`（`docker-compose.yml:229`），
`package.json:48-61` 的 12 個 devDependencies 幾乎全是 `^`/`~` range（例如 `ava: ^4.1.0`、`typescript: ~4.6.2`）。
→ 同一個 commit 在不同時間可解析出不同版本；且 `typescript: ~4.6.2`（`:60`）+ `strict: true`（`tsconfig.json:12`）
的組合一旦上游小數升級就可能把 build 打紅，而 CI 無任何版本鎖可復原。

**根因 R3（叢集 bootstrap 命令的位址表有筆誤）**：`docker-compose.yml:89` 建立單叢集時傳入
`10.0.0.11, 10.0.0.12, 10.0.0.13, 10.0.0.14, 10.0.0.14, 10.0.0.16`——
**`10.0.0.14` 重複、`10.0.0.15` 缺席**；但 `10.0.0.15` 對應的 `redis-single-cluster-5` 確實被定義（`:67-76`）、
也被 `redis-single-cluster` 列入 `depends_on`（`:95`）、亦列入 `runner` 的 `depends_on`（`:271`）。
`--cluster-replicas 1`（`:89`）要求 6 個節點對半分成 3 主 3 從；唯一節點只剩 5 個時該命令會直接拒絕。
相對地，`redis-multi-cluster-a/b/c` 的三條 bootstrap 命令位址皆正確（`:134`、`:175`、`:216`，各 3 節點、`--cluster-replicas 0`）。
下游效果見 §2.6（R4）與 `single`/`cluster` 這 9 個案例（`single.test.ts:550`）。

**根因 R4（等待式前置 + 無 timeout 設定 = 失敗被誤判）**：
`waitForCluster()` 的兩個 `while` 迴圈**無上限、無 deadline**，僅 `sleep 1000`
（`single.test.ts:43-48` 的 ready 等待、`:59-64` 的 writable 等待；`multi.test.ts:43-48`、`:59-64` 為同一邏輯副本）。
`package.json:43-47` 未設定 AVA `timeout`，故採 AVA 預設 10 秒「無新測試結果即 timeout」的機制
（外部依據：<https://raw.githubusercontent.com/avajs/ava/HEAD/docs/07-test-timeouts.md>，本 run 已取得，見附錄 A7）。
→ 当 R3 讓叢集永遠組不起來時，**症狀是 test file 被 timeout 打紅，而非「cluster 建立失敗」**，
除錯資訊指向錯誤的方向。實測：三個 `redis-*` 主機名稱在本沙箱 `getent hosts` 全部無法解析（附錄 A2），
故本 run 無法用執行方式重現，只能靜態推導（誠實標記於 §2.10）。

**根因 R5（dev 導向的 compose 被 CI 直接復用）**：`builder`/`runner` 的預設 `command` 是 watch 模式
（`docker-compose.yml:247` = `yarn build:development`；`:289` = `yarn test:development`），
`tty: true`（`:248`、`:290`），靠 `await.sh` 的「等檔案出現」把 watch 流水線接成一次性命令。
CI 需要的是「依序、可重現、失敗即停」，現有機制提供的是「非同步、靠等待、等待無上限」——
這是 R4 能成立的結構原因。

### 2.5 其他基線觀察（衛生與工具鏈版本）

| 觀察 | 出處 |
|---|---|
| **repo 內 commit 了一個 AVA 快取檔**：`dist/esm/node_modules/.cache/ava/failing-tests.json`，內容為 `[]` | `git ls-files dist`；檔內容（附錄 A5）。`.gitignore:6` 是錨定的 `/node_modules`，故 `dist/esm/node_modules/**` 不在忽略範圍 |
| CodeQL workflow 亦只認 `main` + 每週排程，且用 `github/codeql-action/*@v1`（已淘汰大版本） | `.github/workflows/codeql-analysis.yml:3-9`、`:23`、`:27`、`:29` |
| `ci.yml` 與 `codeql-analysis.yml` 都用 `actions/checkout@v2`（現行主流為 v4） | `ci.yml:14`、`codeql-analysis.yml:21` |
| README **未**說明測試怎麼跑、需要哪些外部服務（Issue 的前提成立），但把開發資訊指向 CONTRIBUTING.md；CONTRIBUTING 有 `docker compose up` 與 `docker compose run --rm runner yarn test` 兩条指令，**未**提及主機名稱清單、23 個 service、`yarn test` 是跑 `dist/esm` 產物 | `README.md:161`、`CONTRIBUTING.md:3`、`:5`、`:10`、`:18` |
| `docker-compose.yml` 内容與上游 `mike-marcacci/node-redlock@main` **完全一致**（byte-identical） | 附錄 A5（`diff -q` 無輸出、`diff_rc=0`）→ 上述 R3 屬上游帶入，非 fork 引入 |
| 工廠高風險路徑 H5 涵蓋 `.github/**`，**本 run 未觸碰**；報告寫入 `docs/research/`（H5 之外） | `.github/factory/risk-paths.yml:56-60` |
| 已存在的可執行規格與 traces（分析下游時相關） | `git ls-files specs` → `specs/redlock/{model,invariants,instances}.qnt`、`source.md`、`verify.yml`、`traces/*.itf.json` |

### 2.6 為何「綠燈」目前是未证明的狀態（而非「红燈」）

Issue #19 的 DoD 第三項要求「跑測試確認綠燈」。本 run 的實測限制：

- 無 `node_modules`（`ls -d node_modules` → 不存在，附錄 A2）→ 無法執行 `tsc` 或 `ava` 的 repo 版本；
- 無 Redis 主機可解析（附錄 A2）、本機 6379 無監聽（附錄 A2）；
- 安裝依賴=新增/固定套件（停手規則 SR5 與本類型「不改設定檔/依賴」雙重限制）→ **不執行 `yarn install`**；
- `docker compose up` 需要 27 個 service（附錄 A4），屬「需外部服務的整合/E2E 級執行」，DoD 本身也把它排除在綠燈要求之外。

因此本報告對「綠燈與否」**不下結論**，只確定：**目前沒有任何机械證據（Actions run）能證明它綠**（§2.4 R1）。
可在沙箱內完成的替代驗證只有「靜態可核對性」：compose 檔可被 compose v2 成功解析（附錄 A4）、
所有測試主機名稱有對應 service（§2.3）、CI 命令字串可回溯（§2.4）。→ 需工作項 W2（見 §5）在有人類提供的
Redis/compose 環境中取得一次可重現的基線執行紀錄。

---

## 3. 影響範圍

| 對象 | 受什麼影響 | 出處 |
|---|---|---|
| **工廠 PR 的放行判斷** | `software-factory` 上的 PR（含 #15–#17 與本 PR）**不會觸發 `ci.yml`**；CI 狀態不可作為这些 PR 的機械證據 | `ci.yml:4-7`、附錄 A3 |
| **`src/index.ts` 的每一次核心修改** | 其行為主要由**需要 Redis 的 24 個案例**守護；若叢集 bootstrap 失敗（R3/R4），`single`/`cluster` 9 個案例的護欄實際失效 | `single.test.ts:550`、`docker-compose.yml:89` |
| **Redlock 演算法的核心邏輯（多數決/重試）** | 本報告**未發現核心演算法缺陷**；R3 的缺陷在**測試基礎設施**（compose），不在 `src/`。紅/綠取決於環境，故任何後續 agent 都可能在「未變更 `src/`」的情況下看到不同結果 | `index.ts:451-454`、`:593-594`、`docker-compose.yml:89` |
| **依赖本 repo 的下游（fork 的使用者）** | 发布產物由 `files`（`package.json:30-38`）+ `prepare`（`:69`）决定；`dist/**` 不進版控（`.gitignore:3-5`）→ 產物品質完全依懶 `tsc`/`typescript ~4.6.2` 的可重現性（R2） | `package.json:30-38,69` |
| **新加入的開發者** | README 未說明測試前提（僅指向 CONTRIBUTING，`README.md:161`），CONTRIBUTING 未列 Redis 主機/服務（`CONTRIBUTING.md:3-19`）→ 在不跑 docker 的環境直接 `yarn test` 必紅（`dist/esm` 为空、主機無法解析） | `package.json:67`、附錄 A2 |
| **未來任何 Dependabot / 升級工作項** | semver range + 無 lockfile（`package.json:48-61`、`.gitignore:10`）使「依賴升級」與「CI 抖动」無法區分 | 同左 |
| **工廠治理 / 高風險路徑** | 若採方案 A 的任何實作步驟，需要修改 `.github/**`（H5，`risk-paths.yml:56-57`）與 `package.json`/`docker-compose.yml` → **超出 `agent-analyze` 許可，必须由人類開工並裁量** | `.github/factory/risk-paths.yml:56-60` |
| ** Quint 規格下游** | `specs/redlock/verify.yml` 與 traces 是本 repo 既有的第二套「驗證面」；本報告的 W3（見 §5）在動 CI 之前應先确认兩套驗證面的分工，避免重複投資 | `git ls-files specs` |

---

## 4. 方案比較（含被拒方案與理由）

> 本類型不實作（docs/06 §4）。以下只比較方案，供人類據以開工。

### 方案 A（建議）：**「先讓 CI 存在，再讓 CI 可重現，最後才碰測試基礎設施」**三階段最小風險改造

1. **A-1 觸發面**：在 `ci.yml` 的 `on:` 增加工廠 trunk（`software-factory`）與 `workflow_dispatch`
   （現為 `ci.yml:4-7` 只認 `main`）。
   - 優點：一行級别的變動即可让每個工廠 PR 得到機械證據；不改測試、不改容器。
   - 缺点：立刻暴顯 R3/R4 的真實状态（可能从「無 CI」變成「CI 紅」）。人類可先以「只開 lint/build 兩個 job、test job 先標可失敗」分两步進。
   - **需人類裁量**：`.github/**` 受 H5 保護（`risk-paths.yml:56-57`）。
2. **A-2 可重現性**：提交 lockfile（撤除 `.gitignore:10` 對 `yarn.lock` 的忽略）或改用 `yarn install --frozen-lockfile`
   + 固定 `installer`/`builder`/`runner` 的 image tag（現為浮動 `node:16`，`docker-compose.yml:227,244,286`）。
   - 優點：把 R2 的抖动變成可偵測的 diff；讓「依賴升級」工作項可行。
   - 缺点：新增一個進版控的大檔（lockfile），属人類裁量範圍。
3. **A-3 基礎設施正確性**：修 `docker-compose.yml:89` 的 `10.0.0.14`→`10.0.0.15`，並為 `redis-*` 加 healthcheck、
   給 `waitForCluster()` 一個明確 deadline（`single.test.ts:34-65`）。
   - 優點：直接消除 R3/R4；測試失败時的訊息不再誤導。
   - 缺点：需要改 `src/*.test.ts`（Issue #19 明確說「不改測試」）→ **必須另開工作項**，且改動面 4 檔。

### 方案 B（被拒）：用 GitHub Actions 的 `services:` 內建 Redis 取代 docker-compose

- 內容：在 job 上宣告 `services: redis` 之類，直接把 `yarn test` 跑在 runner 本機。
- **被拒理由**：測試把 service 名稱當主机名硬編碼（`single.test.ts:548`、`:550`、`multi.test.ts:319-321`、`:326-328`），
  `127.0.0.1` 的失敗路徑測試（`single.test.ts:204-211`）也依赖「連不到」這個前提；改用 `services:` 需同時改 5 处主機名稱
  且会與失敗路徑測試相互矛盾（port 6379 若绑到本機就變成「連得到」）。等於用更大的代價换一点速度。

### 方案 C（被拒）：把測試框架從 AVA 遷到 Jest / vitest / `node --test`

- **被拒理由**：（1）Issue #19 範圍明示「只新增一份文件，不改程式碼、測試、`ci.yml` 與 README」；
  （2）遷移需要同時動 `package.json:43-47`（ava 設定）、`:53`、`:67-68`、5 個測試檔與 `ci.yml:26`；
  （3）本 fork 的 `docker-compose.yml` 與上游 byte-identical（附錄 A5），換框架会让 fork 與上游結構性分歧，
  提高未來 sync 上游修正的成本；（4）沒有證據顯示 AVA 是當前問題的成因——成因是**觸發面與環境**（R1/R3/R5）。

### 方案 D（被拒）：在本沙箱直接 `yarn install && yarn build && yarn test` 取一次綠燈證據

- **被拒理由**：需要安裝 12 個 devDependencies 並在無 Redis 的環境執行 24 個需要 Redis 的案例
  （實測主機名稱不可解析，附錄 A2）。前者觸及「新增未鎖定相依」與設定檔改動的邊界（SR5 + 本類型白名單只允許 `docs/research/`），
  後者放寬斷言必紅。→ 依 factory-stop-rules **不猜測、不繞過**，改為開工項 W2 由人類提供環境。

### 方案 E（被拒）：只更新 README／CONTRIBUTING 的開發文件，不動 CI

- **被拒理由**：文件只解決 §3「新加入的開發者」一項，對「工廠 PR 沒有 CI」（R1）毫无帮助；
  R1 是本盤點里**唯一會影響每一次放行判斷**的結構性缺口，不可用文件替代。

---

## 5. 建議下一步（可直接開成工作項）

> 每項含類型建議、驗收條件草案（可直接作為 Issue 的「驗證方式」欄位與 G8 `requirements[].id`）。

### W1｜`agent-update-deps`／或人類直接處理：讓 CI 對 `software-factory` 生效
**描述**：修改 `.github/workflows/ci.yml:4-7`，把工廠 trunk `software-factory` 納入 `on.push.branches`
與 `on.pull_request.branches`，並加 `workflow_dispatch` 以利人工重放；先以「lint + build 两个 job 必綠、
test job 允許失敗（`continue-on-error: true`）」進，基線綠燈後再收緊。
**驗收條件草案**：
- `REQ-W1-1`：一個針對 `software-factory` 的 PR 可在 Actions 分頁看到 `Continuous Integration` run（可觀察：run URL/ID）。
- `REQ-W1-2`：`ci.yml` 的 `on:` 不再只有 `[main]`；檔案 diff 只觸及 `on:` 區塊（引用行號於 PR 描述）。
- `REQ-W1-3`：若 test job 仍紅，紅的**原因須被記錄为 Issue**（不得以 `continue-on-error` 掩蓋而不回報）。
**風險**：觸及 `.github/**`（H5，`.github/factory/risk-paths.yml:56-57`）→ **必須人類核准**，agent 不得自改（SR3）。

### W2｜`agent-add-tests`／人類執行：取得一次可重現的基線執行紀錄
**描述**：在有 docker 與 27 個 compose service 的環境（`docker compose config --services` 實測值，附錄 A4）
執行 `docker compose run --rm --no-TTY builder yarn lint && … yarn build && … runner yarn test`
（即 `ci.yml:22,24,26` 的命令），把完整輸出與每個 namespace 的案例通過數寫進
`docs/research/<issue>-test-ci-baseline-run.md`，作為 §2.6 「不下結論」的填補。
**驗收條件草案**：
- `REQ-W2-1`：紀錄含 commit SHA、Node image digest、`yarn install` 解析出的 `ava`/`typescript`/`ioredis` 實際版本。
- `REQ-W2-2`：32 個案例（§2.2 口徑）逐一標註 pass/fail，且 `single|cluster` 與 `multi|cluster` 兩组分开統計（R3 的症狀只在 cluster 组）。
- `REQ-W2-3`：若出现 timeout 型失敗，須附上 `Waiting for cluster to be ready...`（`single.test.ts:45`）是否出現的證據。
- `REQ-W2-4`：本工作項**不得**为了让綠燈而修改斷言（factory-stop-rules「絕不允許」條款）。

### W3｜`agent-fix-bug`：修 `docker-compose.yml:89` 的叢集 bootstrap 位址（R3）
**描述**：先寫一個**不依賴 Redis 的红燈測試**（例如以 shell/`docker compose config` 解析 service 列表，
比對 `--cluster create` 參數中的位址集合是否等於 `10.0.0.11`–`10.0.0.16` 的集合），再修正该行把
第二個 `10.0.0.14:6379` 改為 `10.0.0.15:6379`。同時評估 `redis-multi-cluster-*` 三條命令（`:134,175,216`）
以同一个断言涵蓋。
**驗收條件草案**：
- `REQ-W3-1`：紅燈測試在修正前失败、修正後通過（同一 commit 對照）。
- `REQ-W3-2`：斷言檢查的位址集合取自 compose 檔本身（不得把 6 个 IP 抄進測試造成雙重真相）。
- `REQ-W3-3`：`docker-compose.yml` 的 diff 只有一行（或四行，若一併比對 `:134,175,216`）。
- `REQ-W3-4`：在 Issue 中標註**上游同缺陷**（附錄 A5），並由人類決定要不要向上游 PR。
**風險**：`docker-compose.yml` 属測試基礎設施、非 H5，但改動会影响 `ci.yml:26` 的結果 → 建議在 W1 之後執行。

### W4｜`agent-write-docs`：把「怎麼跑測試」寫進 CONTRIBUTING（不碰 src/、不碰 ci.yml）
**描述**：在 `CONTRIBUTING.md:3-19` 現有內容基礎上補三節：（1）`yarn test` 實際跑的是 `dist/esm/*.test.js`
（`package.json:67`、`tsconfig.json:6,16`），必须先 `yarn build`；（2）7 个 Redis 主機名稱與其 service 對照表
（本報告 §2.3 可直接引用）；（3）不需要 Redis 的 8 个案例清單（§2.2）。
**驗收條件草案**：
- `REQ-W4-1`：文件內每個陳述附 `檔案:行號`。
- `REQ-W4-2`：新增段落與 `package.json`/`docker-compose.yml` 現況一致（由審查者逐條核對）。
- `REQ-W4-3`：不改 `README.md`、`src/**`、`.github/**`。

### W5｜治理類（人類）：`dist/esm/node_modules/.cache/ava/failing-tests.json` 的去留
**描述**：该檔被誤 commit（`git ls-files dist`，内容 `[]`；`.gitignore:6` 只錨定根目錄 `/node_modules`）。
建議人類決定加 ignore pattern 或 `git rm`；**本 run 未處理**（不在 `docs/research/` 白名單內）。

---

## 6. 未決事項（需人類回答，agent 不猜測）

- **Q1**：本 fork 的 `actions/workflows` API 回傳空清單、`actions/runs` 回 `total_count = 0`（附錄 A3）。
  是「從未跑過」還是「token 無 Actions 讀權」？若是後者，W1 完成後应重測。
- **Q2**：`software-factory` 是最終形態的 trunk，還是會回合到 `main`？若會回合，W1 只需加 `workflow_dispatch`；
  若不會，`ci.yml:5,7` 的 `[main]` 应整段替換。
- **Q3**：Issue #19 的「已知問題：測試依賴 Redis，不得在沒有 Redis 的環境執行測試」——本盤點發現
  **5 個測試檔裡有 3 個（8 个案例）不需要 Redis**（`quorum.test.ts:5-14`、`acquire-expiration.test.ts:14`、`extend.test.ts`）。
  該前提是否应縮小为「僅 `single.test.ts`/`multi.test.ts`」？（範圍歧義 → 停手規則 8 的邊界，故以問題形式回報，不自行改寫 Issue。）
- **Q4**：`ci.yml:16` 用的 `satackey/action-docker-layer-caching@v0.0.11`（`continue-on-error: true`）是第三方且多年未更新；
  是否允許以 GitHub 官方 `actions/cache` 取代（属 `.github/**`，H5）。
- **Q5**：`node:16` 基鏡與 `engines.node >= 12`（`package.json:39-41`）都超出上游支援時程；
  人類可接受的目標 Node 版本为何？（本 run 的實測：`--experimental-specifier-resolution=node`
  在 Node **v22.21.1** 仍被接受且不报警告（附錄 A2）→ 此旗標**不是**升級阻礙，但应改用 `--experimental-*` 以外的正規做法，需人類决定。）
- **Q6**：`specs/redlock/verify.yml` 的 Quint 驗證面（`git ls-files specs`）是否已计入工廠的「CI 證據」定義？
  若已计入，W1 的 `ci.yml` 改造范围可縮小。

---

## 附錄 A：可重現步驟與原始輸出

以下命令均在本 run 的沙箱（工作目錄 = repo checkout @ `8371226056b85ca70632e91ec9b0d5236336f41b`）執行，輸出原樣記錄。

### A1 分支與 commit 基線

```
$ git rev-parse HEAD
8371226056b85ca70632e91ec9b0d5236336f41b
$ git log -1 --format='%H %d'
8371226056b85ca70632e91ec9b0d5236336f41b  (grafted, HEAD -> software-factory, origin/software-factory)
$ git ls-files src
src/acquire-expiration.test.ts
src/extend.test.ts
src/index.ts
src/multi.test.ts
src/quorum.test.ts
src/single.test.ts
```

（註：checkout 為 shallow/grafted，故本 run 無法提供完整 ancestry。）

### A2 環境與「無法在本沙箱跑整合測試」的證據

```
$ node --version
v22.21.1
$ docker --version
Docker version 28.0.4, build b8034c0
$ which docker-compose
docker-compose: command not found
$ ls -d node_modules            → 無輸出（目錄不存在）
$ for h in redis-single-instance redis-multi-instance-a redis-single-cluster-1; do getent hosts $h; done
redis-single-instance NXDOMAIN/unresolvable
redis-multi-instance-a NXDOMAIN/unresolvable
redis-single-cluster-1 NXDOMAIN/unresolvable
$ (exec 3<>/dev/tcp/127.0.0.1/6379)     → 失敗（本機 6379 無監聽）
$ node --experimental-specifier-resolution=node -e "console.log(1)"
1                      ← 無錯誤、無棄用警告（Node v22.21.1）
```

### A3 GitHub 端事實

```
$ gh api repos/tradingbot-tw/node-redlock --jq '.default_branch'
main
$ gh api "repos/tradingbot-tw/node-redlock/actions/runs?per_page=1" --jq '.total_count'
0
$ gh api "repos/tradingbot-tw/node-redlock/actions/workflows" --jq '.workflows[] | .name + " | " + .path'
（無輸出）
$ gh pr list --state all
#15 #16 #17 = factory/6-01-test / 6-02-impl / 6-03-docs（MERGED）
#7  #8  #9  = factory/4-01-test / 4-02-impl / 4-03-docs（MERGED）
#11 #12 #13 = factory/5-01-test / 5-02-impl / 5-03-docs（MERGED）
#2  #3      = factory/1-01-invariants / 1-01-model（MERGED）
```

### A4 compose 解析與主機名稱對照（REQ-4 的機械核對）

```
$ docker compose config --services | sort | tee /tmp/services.txt
builder, installer, redis-multi-cluster-{a,b,c}, redis-multi-cluster-{a,b,c}-{1,2,3},
redis-multi-instance-{a,b,c}, redis-single-cluster, redis-single-cluster-{1..6}, redis-single-instance  （共 27 行）
$ wc -l < /tmp/services.txt
27
$ grep -c '^redis' /tmp/services.txt
23
$ grep -ho -E 'host: "[a-z0-9-]+"' src/*.test.ts | sort -u
host: "redis-multi-cluster-a-1"   host: "redis-multi-instance-a"
host: "redis-multi-cluster-b-1"   host: "redis-multi-instance-b"
host: "redis-multi-cluster-c-1"   host: "redis-multi-instance-c"
host: "redis-single-cluster-1"    host: "redis-single-instance"
（另：src/single.test.ts:205 的 host: "127.0.0.1" 因含小數點不被上述 pattern 命中，已於 §2.3 單列）
警告（compose v2 對 docker-compose.yml:1）：the attribute `version` is obsolete, it will be ignored
```

### A5 dist 檔與上游比對

```
$ git ls-files dist
dist/cjs/package.json
dist/esm/node_modules/.cache/ava/failing-tests.json
dist/esm/package.json
$ cat dist/esm/node_modules/.cache/ava/failing-tests.json
[]
$ curl -sS https://raw.githubusercontent.com/mike-marcacci/node-redlock/main/docker-compose.yml -o /tmp/upstream-compose.yml
$ diff -q /tmp/upstream-compose.yml docker-compose.yml ; echo $?
0                      ← 完全相同（含 :89 的 10.0.0.14 重複／10.0.0.15 缺席）
```

### A6 案例與斷言計數口徑

```
$ for f in src/*.test.ts; do
    n=$(grep -c -E '^\s*test\(|^\s*test\.\w+\(' $f)
    a=$(grep -o -E 't\.(is|assert|true|false|fail|pass|throws|not|deepEqual)\(' $f | wc -l)
    echo "$f test-calls=$n assertions=$a"; done
src/acquire-expiration.test.ts test-calls=2  assertions=2
src/extend.test.ts             test-calls=3  assertions=3
src/multi.test.ts              test-calls=5  assertions=38   ← 5 = 3 個案例 + 2 個 test.before（:73, :87）
src/quorum.test.ts             test-calls=3  assertions=13
src/single.test.ts             test-calls=11 assertions=60   ← 11 = 9 個案例 + 2 個 test.before（:68, :74）
$ grep -c 'test(`${namespace}' src/single.test.ts src/multi.test.ts
src/single.test.ts:9   src/multi.test.ts:3
```

### A7 AVA timeout 預設值的來源

- <https://raw.githubusercontent.com/avajs/ava/HEAD/docs/07-test-timeouts.md>（「The default timeout is 10 seconds.」，
  採「每個新測試結果重置計時器」的 inactivity 語意）。本 repo 未覆寫（`package.json:43-47`）。
