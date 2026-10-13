# Issue #19 現況分析：node-redlock（tradingbot-tw）測試結構與 CI 設定

> 文件型別：`agent-analyze` 產出（分析／現況盤點）。**本報告不具放行效力**，只描述現況與
> 可選方案，不含任何程式碼、測試或設定變更（docs/06 §4「僅可產出分析與方案，不得實作」）。
> 人類審查後才可能據以開立新的工作項。

---

## 0. 描述基準（本文件描述的是哪個 commit）

| 項目 | 值 | 出處 |
| --- | --- | --- |
| Repo | `tradingbot-tw/node-redlock` | 任務描述、`catalog-info.yaml:29`（`github.com/project-slug`） |
| 分支 | `software-factory` | `git branch --show-current`；Issue 需求描述明示「以 `software-factory` 分支為準」 |
| Commit SHA | `8371226056b85ca70632e91ec9b0d5236336f41b`（`Merge pull request #17 from tradingbot-tw/factory/6-03-docs`） | `git rev-parse HEAD` |
| 相對 `main` | 領先 25、落後 0 | GitHub compare API `repos/tradingbot-tw/node-redlock/compare/main...software-factory`（`ahead_by:25, behind_by:0, status:"ahead"`） |
| `main` 身份 | 上游 `mike-marcacci/node-redlock@afe5cf92c8247ba7b65b4ae36230f415493c44f0` | `catalog-info.yaml:6`；`git ls-remote --heads origin` 的 `refs/heads/main` 亦為 `afe5cf9` |

**分歧是否成立**：成立。`software-factory` 的 25 個 commit 全為工廠工作（納管設定、Quint 規格、
Issue #4／#5／#6 的測試與修復、文件），無任何上游新提交；`main` 仍停在上游 `afe5cf9`
（"fix spell error in readme (#300)"）。本工作項的 PR base 應為 `software-factory`，非 `main`。

本文件描述的工作樹即上述 SHA；除本報告檔外，本次未變更任何檔案。

---

## 1. 結論摘要（一頁內）

1. **測試框架**：AVA `^4.1.0`（`package.json:53`），測試以 TypeScript 撰寫於 `src/*.test.ts`，
   由 `tsc` 編譯成 ESM 到 `dist/esm` 後執行（`tsconfig.json:6,10,16`；`dist/esm/package.json:1-3`）。
   AVA 以 `nodeArguments: ["--experimental-specifier-resolution=node"]` 啟動（`package.json:43-47`）。
2. **`package.json` 的三個關鍵 script**（`package.json:64,65,67`）：
   - `lint` = `prettier -c '**/*.{json,yml,md,ts}' && eslint src --ext ts`
   - `build` = `rm -f dist/**/*.{js,js.map,d.ts} && tsc && tsc -p tsconfig.cjs.json`
   - `test` = `cd dist/esm && ava --verbose *.test.js`
   三個都是「先 `build` 才能 `test`」的關係；`test` 不會自動建置。
3. **`ci.yml` 只在 `push`/`pull_request` 對 `main` 時觸發**（`.github/workflows/ci.yml:3-7`）。
   因此**對 `software-factory` 的 PR 不會觸發這個 workflow**；工廠的品質閘門是本 workflow 之外的機制。
4. **CI 執行內容**（`.github/workflows/ci.yml:14-29`）：checkout → docker layer cache（可失敗）→
   `docker-compose pull`（可失敗）→ `docker compose run --rm --no-TTY builder yarn lint` →
   `... builder yarn build` → `... runner yarn test` → `docker compose down`。
5. **測試需要 Redis，且由 `docker-compose.yml` 提供**：單程序測試連 `redis-single-instance`
   （`src/single.test.ts:548`），叢集測試連 `redis-single-cluster-1`（`src/single.test.ts:550`）；
   多節點測試連 `redis-multi-instance-a/b/c`（`src/multi.test.ts:319-321`）與
   `redis-multi-cluster-a-1/b-1/c-1`（`src/multi.test.ts:326-328`）。上述名稱與 compose 服務名稱一一對應
   （`docker-compose.yml:15,27,19,21,23,102,143,184`）。
6. **並非全部測試都需要 Redis**：`src/quorum.test.ts`、`src/acquire-expiration.test.ts`、`src/extend.test.ts`
   使用 stub client（`src/quorum.test.ts:9-14`、`src/acquire-expiration.test.ts:43-75`、`src/extend.test.ts:10-22`），
   但 `yarn test` 的 glob `*.test.js` 會一次跑完 5 個檔案（`package.json:67`），
   所以**沒有「無 Redis 子集」的官方入口**，整體 suite 仍必須有 Redis 才能跑。
7. **文件缺口**：`README.md:159-161` 只把使用者導向 `CONTRIBUTING.md`；`CONTRIBUTING.md:3-18`
   只給了 `docker compose up` 與 `docker compose run --rm runner yarn test` 兩個指令，
   未提 `lint`/`build`、未提 `ci.yml`、未做 Redis 服務對照。這是 Issue 所述「README 沒有說明
   測試怎麼跑」的直接根因。
8. **殘留的死設定**：`.travis.yml:8` 的 `npm run test-ci` 在 `package.json` 已不存在
   （scripts 僅 `package.json:62-71`），`.coveralls.yml:1` 仍寫 `travis-ci`；兩者皆為上游舊 CI 殘留。

---

## 2. 測試結構盤點

### 2.1 框架、組譯與執行模型

- **框架**：AVA 4（`package.json:53` 的 `"ava": "^4.1.0"`），設定僅 `nodeArguments`
  （`package.json:43-47`）；無 `ava.config.*`、無 `test` 目錄。
- **語言／模組**：TypeScript + ESM。`package.json:75` 為 `"type": "module"`；
  `tsconfig.json` 的 `outDir` 為 `./dist/esm`（`tsconfig.json:6`）、`rootDir` 為 `./src`
  （`tsconfig.json:10`）、`include` 為 `./src/**/*`（`tsconfig.json:16`）——**測試檔與實作一同被編譯**。
- **CJS 產物**：`tsc -p tsconfig.cjs.json` 另外輸出 `dist/cjs`（`tsconfig.cjs.json:7`），
  但測試只跑 ESM 產物（`package.json:67`）。
- **ESM 標記檔**：`dist/esm/package.json` 內容為 `{"type":"module"}`（`dist/esm/package.json:1-3`），
  隨版本控制提交，確保 `dist/esm` 下的 `.js` 以 ESM 解讀。
- **執行前提**：`test` 前必須先 `build`（`package.json:65,67`）；CI 的步驟順序即據此
  （`.github/workflows/ci.yml:23-26`）。`dist` 內只有 `package.json` 被提交，`*.js` 被
  `.gitignore` 排除（`.gitignore:3-5`；`git ls-files dist` 僅見 `dist/cjs/package.json`、
  `dist/esm/package.json`、`dist/esm/node_modules/.cache/ava/failing-tests.json`）。
- **併發與 hook**：AVA 預設會併發執行測試。每個測試檔用 `run(...)` 註冊案例並以 `test.before`
  建立檔案級前置（`src/single.test.ts:68-78`、`src/multi.test.ts:73-93`）。`single.test.ts`
  呼叫 `run()` 兩次（`src/single.test.ts:548,550`），`multi.test.ts` 亦呼叫兩次
  （`src/multi.test.ts:317-329`）；由於 AVA 的 `test.before` 是**檔案級** hook，兩個 `run()`
  合計註冊 4 個 before hook，全部會在該檔任何測試前執行——instance 案例也會觸發 cluster 的
  `waitForCluster` 與 keys 清除，反之亦然。此點值得後續文件化時一併說明。

### 2.2 案例分組方式

- 分組靠 `run(namespace, client...)` 這個自製 helper（`src/single.test.ts:67`、`src/multi.test.ts:67-72`），
  把同一組案例用 `"${namespace} - ..."` 前綴命名。命名空間為 `instance` 與 `cluster` 兩種。
- 測試標題內含命名空間（例：`src/single.test.ts:98` `"${namespace} - acquires, extends, and releases a single lock"`），
  因此 `ava --verbose` 的輸出可看出案例屬於哪一組。
- 失敗診斷集中在 `fail()` helper：把 `ExecutionError` 展開為每個 attempt 的
  membership/quorum/votes 統計（`src/single.test.ts:6-32`、`src/multi.test.ts:6-32`）。
- 叢集就緒等待由 `waitForCluster()` 負責（`src/single.test.ts:34-65`、`src/multi.test.ts:34-65`）。

### 2.3 各測試檔、案例數與外部服務依賴

| 測試檔 | 行數 | 案例數（`test(...)`） | 連線的 Redis | 需要 Redis？ |
| --- | --- | --- | --- | --- |
| `src/single.test.ts` | 550 | 9 × 2 namespace = 18 | `redis-single-instance`（:548）、`redis-single-cluster-1`（:550） | **是**；另含 1 個刻意連不存在的 `127.0.0.1`（:204-205）以驗證連線失敗 |
| `src/multi.test.ts` | 329 | 3 × 2 namespace = 6 | `redis-multi-instance-a/b/c`（:319-321）、`redis-multi-cluster-a-1/b-1/c-1`（:326-328） | **是** |
| `src/quorum.test.ts` | 105 | 3 | stub client，不連網（:9-14） | 否 |
| `src/acquire-expiration.test.ts` | 125 | 2 | stub client，不連網（:43-75） | 否 |
| `src/extend.test.ts` | 63 | 3 | stub client，不連網（:10-22） | 否 |
| **合計** | — | **32** | — | 5 檔中 2 檔需 Redis（24／32 個案例） |

> 案例數以 `grep -c 'test('` 統計（`src/single.test.ts` 9、`src/multi.test.ts` 3、
> `src/quorum.test.ts` 3、`src/acquire-expiration.test.ts` 2、`src/extend.test.ts` 3），
> `run()` 呼叫次數為 2（`src/single.test.ts:548,550`、`src/multi.test.ts:317,324`）。

---

## 3. `package.json` scripts 實際執行的命令

`package.json:62` 為 `"scripts"` 物件，完整內容（`package.json:63-70`）：

| Script | 實際命令 | 出處 |
| --- | --- | --- |
| `format` | `prettier --list-different --write '**/*.{json,yml,md,ts}'` | `package.json:63` |
| `lint` | `prettier -c '**/*.{json,yml,md,ts}' && eslint src --ext ts` | `package.json:64` |
| `build` | `rm -f dist/**/*.{js,js.map,d.ts} && tsc && tsc -p tsconfig.cjs.json` | `package.json:65` |
| `build:development` | `rm -f dist/**/*.{js,js.map,d.ts} && tsc --watch` | `package.json:66` |
| `test` | `cd dist/esm && ava --verbose *.test.js` | `package.json:67` |
| `test:development` | `cd dist/esm && ava --verbose --watch *.test.js` | `package.json:68` |
| `prepare` | `yarn build` | `package.json:69` |
| `prepublishOnly` | `yarn install && yarn lint && yarn build` | `package.json:70` |

補充事實：

- `lint` 的第一段是 **prettier 檢查整個 repo 的 json/yml/md/ts**，不只 `src/`；第二段才是
  eslint 掃 `src`（`package.json:64`）。eslint 設定在 `.eslintrc.json:1-18`，
  忽略清單只有 `dist`、`node_modules`（`.eslintignore:1-2`）；prettier 忽略清單相同
  （`.prettierignore:1-2`）。
- `test` 的 `*.test.js` 由 shell（容器內為 Debian `node:16` 的 sh）在 `dist/esm` 展開，
  因此執行的是 5 個編譯後測試檔；AVA 本身不吃 `**` glob（這裡的展開是 shell 做的）。
- `test` 沒有前置 `build`；直接 `yarn test` 會因 `dist/esm` 不存在或過期而失敗／跑到舊產物。
- `package.json:30-38` 的 `files` 白名單只含 `dist/**/index.*`，所以測試檔不會被發佈到 npm。
- **不存在** `test-ci` script（`.travis.yml:8` 仍引用它）。

---

## 4. `ci.yml` 觸發條件與每個步驟

檔案：`.github/workflows/ci.yml`（共 29 行，`name: Continuous Integration`，`ci.yml:1`）。

### 4.1 觸發條件

```
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
```

出處：`.github/workflows/ci.yml:3-7`。

- **只在 `main` 上的 push 與對 `main` 的 PR 觸發**；沒有 `workflow_dispatch`、沒有排程、
  沒有其他分支。→ 對 `software-factory`（本 Issue 的 base 分支）的 PR **不會**觸發此 workflow。
- 另一個 workflow `codeql-analysis.yml` 觸發條件相同（`codeql-analysis.yml:4-7`）另加每週排程
  （`codeql-analysis.yml:8-9`），語言矩陣為 javascript（`codeql-analysis.yml:17-18`）。

### 4.2 Job 與每個步驟

Job `test`，名稱 `Build & Test`，runner `ubuntu-latest`（`ci.yml:10-12`）：

| # | 步驟名稱 | 執行的命令 | 出處 |
| --- | --- | --- | --- |
| 1 | （checkout） | `actions/checkout@v2` | `ci.yml:14` |
| 2 | Enable docker layer cache | `satackey/action-docker-layer-caching@v0.0.11`（`continue-on-error: true`） | `ci.yml:15-17` |
| 3 | Pull docker images | `docker-compose pull`（`continue-on-error: true`） | `ci.yml:18-20` |
| 4 | Lint the source | `docker compose run --rm --no-TTY builder yarn lint` | `ci.yml:21-22` |
| 5 | Transpile into dist | `docker compose run --rm --no-TTY builder yarn build` | `ci.yml:23-24` |
| 6 | Run tests | `docker compose run --rm --no-TTY runner yarn test` | `ci.yml:25-26` |
| 7 | Stop containers | `docker compose down`（`if: always()`） | `ci.yml:27-29` |

CI 未 `docker compose up` 或 `docker compose build` 任何服務：`docker compose run` 會依
`depends_on` 啟動相依服務（`docker-compose.yml:242-243,261-285`）。第 4、5 步用 `builder`
容器（`docker-compose.yml:241-257`），第 6 步用 `runner` 容器（`docker-compose.yml:260-303`）。

**`await.sh` 閘門機制**（CI 能通過的關鍵，容易被忽略）：`builder` 的 entrypoint 是
`./scripts/await.sh node_modules/.bin/tsc`（`docker-compose.yml:246`），`runner` 的 entrypoint 是
`./scripts/await.sh node_modules/.bin/ava ./scripts/await.sh dist/esm/index.js`
（`docker-compose.yml:288`）。`docker compose run ... <cmd>` 會把 `<cmd>` 接到 entrypoint 參數尾端，
`await.sh` 先等 `$1` 存在、再 `eval "${*:2}"`（`scripts/await.sh:3-10`）。因此：

- `builder yarn lint` → 等 `node_modules/.bin/tsc` 出現（即 `installer` 的 `yarn` 完成，
  `docker-compose.yml:226-229`）後執行 `yarn lint`。
- `runner yarn test` → 等 `node_modules/.bin/ava` 與 `dist/esm/index.js` 都出現
  （即建置完成）後執行 `yarn test`。

`installer`／`builder`／`runner` 共用具名 volume `node_modules`（`docker-compose.yml:4,236-238,255-257,297-299`）
並 bind mount 專案根目錄到 `/workspace`（`docker-compose.yml:232-235,251-254,293-296`），
所以 `builder` 產出的 `dist` 對 `runner` 立即可見。

**兩個容易誤判的細節**：

- CI 混用 Compose v1/v2 二進位：第 3 步是 `docker-compose`（`ci.yml:19`），第 4-7 步是
  `docker compose`（`ci.yml:22,24,26,29`）。
- 第 6 步命令字面是 `yarn test`（`ci.yml:26`）；`runner` 的 compose `command` 是
  `yarn test:development`（`docker-compose.yml:289`），但 `docker compose run` 的引數會覆蓋它，
  所以 CI 跑的是單次 `yarn test` 而非 watch 模式。

---

## 5. 測試連線的 Redis 主機名稱 ↔ `docker-compose.yml` 服務對照

### 5.1 對照表

| 測試檔:行號 | 連線主機名稱 | compose 服務名稱與行號 | compose 映像／角色 |
| --- | --- | --- | --- |
| `src/single.test.ts:548` | `redis-single-instance` | `redis-single-instance:`（`docker-compose.yml:15`） | `redis:6`（:16），單一實例 |
| `src/single.test.ts:550` | `redis-single-cluster-1` | `redis-single-cluster-1:`（`docker-compose.yml:27`） | `redis:6` + `cluster.redis.conf`（:28-36），單一叢集的第 1 節點 |
| `src/multi.test.ts:319` | `redis-multi-instance-a` | `redis-multi-instance-a:`（`docker-compose.yml:19`） | `redis:6`（:20） |
| `src/multi.test.ts:320` | `redis-multi-instance-b` | `redis-multi-instance-b:`（`docker-compose.yml:21`） | `redis:6`（:22） |
| `src/multi.test.ts:321` | `redis-multi-instance-c` | `redis-multi-instance-c:`（`docker-compose.yml:23`） | `redis:6`（:24） |
| `src/multi.test.ts:326` | `redis-multi-cluster-a-1` | `redis-multi-cluster-a-1:`（`docker-compose.yml:102`） | `redis:6`（:103），叢集 A 節點 1 |
| `src/multi.test.ts:327` | `redis-multi-cluster-b-1` | `redis-multi-cluster-b-1:`（`docker-compose.yml:143`） | `redis:6`（:144），叢集 B 節點 1 |
| `src/multi.test.ts:328` | `redis-multi-cluster-c-1` | `redis-multi-cluster-c-1:`（`docker-compose.yml:184`） | `redis:6`（:185），叢集 C 節點 1 |
| `src/single.test.ts:205` | `127.0.0.1` | **刻意不對應任何服務** | 用於「redis unreachable」案例（`src/single.test.ts:202`）；`retryStrategy: () => null`（:209） |
| `src/quorum.test.ts:9-14`、`src/acquire-expiration.test.ts:43-75`、`src/extend.test.ts:10-22` | 無（stub） | 不適用 | 以假 client 取代 ioredis，不連任何主機 |

**名稱完全一致**：測試用的 8 個 hostname 與 compose 服務名稱逐字相同，靠 Compose 的服務名稱
DNS 解析（同一 network 上的容器可用服務名互連）。

### 5.2 為什麼 `runner` 同時接兩個 network

- 單機實例（`redis-single-instance`、`redis-multi-instance-*`）沒有 `networks:` 區塊，
  只加入預設網路。
- 叢集節點（`redis-single-cluster-*`、`redis-multi-cluster-*-*`）明確指定
  `networks: redis`（例：`docker-compose.yml:34-36,109-111`），只加入 `redis` 這個 bridge
  （subnet `10.0.0.0/16`，`docker-compose.yml:6-11`）。
- `runner` 同時加入兩個網路（`docker-compose.yml:300-303`，`redis` 上固定 IP `10.0.10.3`），
  因此單機與叢集 hostname 都解析得到。這是「測試主機名稱能對上服務名稱」的前提。

### 5.3 CI 如何滿足 Redis 依賴

`runner.depends_on` 列出 23 個 redis 服務（`docker-compose.yml:261-285`），
`docker compose run runner ...` 會先啟動它們；叢集由一次性服務 `redis-single-cluster`
（`docker-compose.yml:87-99`）與 `redis-multi-cluster-a/b/c`（`docker-compose.yml:132-141,173-182,214-223`）
執行 `redis-cli --cluster create` 建立。測試端另有 `waitForCluster()` 輪詢
`cluster_state:ok` 與寫入可用性（`src/single.test.ts:34-65`）避免叢集尚未成形就開跑。

---

## 6. 證據與根因（為何 README 答不出「測試怎麼跑」）

本節的「根因」不是程式缺陷，而是**文件與設定的資訊缺口**；每一項附可重現的查證指令與 `檔案:行號`。

### G1：README 完全沒有測試／CI 指令（根因）

- 重現：`grep -nE "yarn (test|build|lint)|docker|ava|ci\.yml" README.md`
  → 只命中第 1 行（上游 CI badge，指向 `mike-marcacci`）與演算法說明文字，**沒有任何可執行指令**。
- 正式入口只有一句：「Please see [`CONTRIBUTING.md`](./CONTRIBUTING.md) for information on
  developing, running, and testing this library.」（`README.md:161`）。

### G2：CONTRIBUTING 只給兩個指令，未涵蓋 lint/build/CI/Redis 對照

- 重現：`sed -n '1,18p' CONTRIBUTING.md`
- 內容僅：Docker 環境說明（`CONTRIBUTING.md:3`）、`docker compose up`（`CONTRIBUTING.md:9-11`）、
  `docker compose run --rm runner yarn test`（`CONTRIBUTING.md:15-18`）。
- 未提 `yarn lint`／`yarn build`（`package.json:64-65`）、未提 `.github/workflows/ci.yml`、
  未提哪些測試對應哪些 Redis 服務（見本報告 §5）。

### G3：`ci.yml` 觸發範圍不含 `software-factory`

- 出處：`.github/workflows/ci.yml:3-7`（僅 `main`）。
- 影響：本 Issue 的 PR base 是 `software-factory`，因此**這個 workflow 不會跑**。
  讀者若以 README/CONTRIBUTING 推斷「CI 會驗證我的 PR」會得到錯誤結論。
- 這不是 bug，而是工廠採外部 CI 的設計結果；但文件必須明講。

### G4：舊 CI 設定殘留且指向不存在的 script

- `.travis.yml:8`：`script: npm run test-ci`；但 `package.json:62-71` 無 `test-ci`。
  重現：`grep -n "test-ci" package.json .travis.yml` → 只命中 `.travis.yml:8`。
- `.coveralls.yml:1`：`service_name: travis-ci`。
- 兩者皆為上游遺留；對照 `README.md:1` 的 badge 也還指向上游帳號。

### G5：相依解析不可重現（無 lockfile）

- `.npmrc:1`：`package-lock=false`；`.gitignore:8` 忽略 `package-lock.json`、`.gitignore:10`
  忽略 `yarn.lock`。
- `installer` 執行不帶 `--frozen-lockfile` 的裸 `yarn`（`docker-compose.yml:229`）。
- 後果：每次 CI／本機安裝可能解析到不同的小版本，`package.json:53` 的 `^4.1.0` 等都是範圍版本。
  這會讓報告 §2.3 的案例數與行為隨時間漂移。

### G6：沒有「不需 Redis」的官方測試入口

- `yarn test` 的 glob `*.test.js`（`package.json:67`）會把 3 個 stub 測試檔
  （`src/quorum.test.ts`、`src/acquire-expiration.test.ts`、`src/extend.test.ts`）與 2 個需 Redis
  的檔案一起跑；沒有 `test:unit` 之類的子集 script（`package.json:62-71`）。
- 後果：開發者在沒有 Redis 的機器上沒有官方方式跑到那 8 個純邏輯案例；但這 8 個案例其實
  完全可以在無 Redis 環境執行（`src/quorum.test.ts:9-14` 等）。此為文件（與可能的 script）缺口，
  非本工作項可修。

---

## 7. 影響範圍

| 受影響對象 | 影響 | 依據 |
| --- | --- | --- |
| 新進開發者／貢獻者 | 無法從 README 得知要 `yarn build` 後才能 `yarn test`、需要 Redis、以及 `lint` 會檢查 md/json/yml | `README.md:159-161`、`CONTRIBUTING.md:3-18`、`package.json:64-67` |
| 本機（無 Docker）開發者 | 誤以為可直接 `yarn test`；實務上需 compose 起的 Redis，或至少需先 `build` | `package.json:67`、`docker-compose.yml:260-303` |
| CI／PR 審查者 | 誤以為 `ci.yml` 會驗證 `software-factory` 的 PR | `.github/workflows/ci.yml:3-7` |
| 工廠 agent（後續工作項） | 缺乏權威的「測試怎麼跑」文件，重跑驗證時得自行逆向 `ci.yml`／compose | 本報告 §3-§5 |
| 上游 fork 使用者 | 承襲上游的 `.travis.yml`／`.coveralls.yml`／README badge 殘留，指向失效的 `test-ci` | `.travis.yml:8`、`.coveralls.yml:1`、`README.md:1` |
| 發佈流程 | `prepublishOnly` 跑 `yarn install && yarn lint && yarn build`（`package.json:70`），但無 lockfile，發佈產物可重現性依賴當下解析結果 | `package.json:70`、`.npmrc:1`、`.gitignore:8,10` |

**不受影響**：`src/index.ts`（本次未讀取實作細節，也未變更）、Quint 規格（`specs/redlock/**`）、
硬規則檔案（`.github/factory/risk-paths.yml`）。

---

## 8. 方案比較（要如何補上這個資訊缺口）

### 方案 A（建議）：新增 `docs/development.md`，並從 README／CONTRIBUTING 連結

把 §3–§5 的內容整理成開發者導向的操作文件（而不是研究報告），在 `README.md:161` 附近與
`CONTRIBUTING.md:3` 附近各加一行連結。

- 優點：只動 docs 層，無 guardrail 風險；不動 `.github/**`（H5，`risk-paths.yml:56-60`）、
  不動 `package.json`；owner 清楚，上游可選擇性 cherry-pick。
- 缺點：多一個檔案；需注意與上游 README 的 diff。

### 方案 B：只擴充 `CONTRIBUTING.md`

- 優點：改動最小、單一檔案。
- 缺點：`CONTRIBUTING.md` 是上游檔案（`CONTRIBUTING.md:1`），擴充會加大與上游的分歧；
  README 的「Guidance → Contributing」入口仍只連到一個偏精簡的上游文件。
  可接受但不如方案 A 清楚。**保留為備選，非被拒**。

### 方案 C（被拒）：修改 `.github/workflows/ci.yml` 觸發範圍，加入 `software-factory`

- 理由：`.github/**` 屬 H5 硬規則（`.github/factory/risk-paths.yml:56-60`），
  需人類裁定；且工廠 CI 外部化是本 repo 既有設計（`catalog-info.yaml:75` 亦顯示
  `agent-automerge: "false"`，所有 PR 都需人類核准）。超出本 Issue「只新增一份文件」的範圍。

### 方案 D（被拒）：新增 `test:unit` script 並拆分測試 suite

- 做法：讓 3 個 stub 測試檔可在無 Redis 環境單獨執行。
- 理由：改 `package.json`（可能還有 CI 行為），超出本 Issue 的範圍；且 Analysis 型別不得實作。
  可列為後續獨立工作項（見 §9 的非目標）。

### 方案 E（被拒）：只保留本報告，不開後續工作項

- 理由：本報告不具放行效力（`docs/06 §4`），缺口仍在；Issue 的驗證方式要求「可直接開成工作項的
  建議下一步」，因此必須提出可執行的下一步。

---

## 9. 建議下一步（可直接開成工作項）

**Title**：`docs: 補齊 node-redlock 測試與 CI 開發者指南（Issue #19 後續）`

**型別**：`agent-write-docs`

**範圍**：

- 修改 `CONTRIBUTING.md` 與 `README.md` 的 Contributing 段；必要時新增 `docs/development.md`。
- **不得**修改 `.github/**`、`package.json`、`src/**`、`specs/**`（`.github/**` 為 H5，
  `risk-paths.yml:56-60`）。

**驗收條件草案（AC）**：

1. 文件列出 `lint`、`build`、`test` 三個 script 的實際命令（對應 `package.json:64,65,67`），
   並明說 `test` 之前必須先 `build`。
2. 文件列出 `ci.yml` 的觸發條件（只有 `main` 的 push/PR，`.github/workflows/ci.yml:3-7`）
   與每個步驟的命令（`ci.yml:14-29`），並明講「對 `software-factory` 的 PR 不會觸發此 workflow」。
3. 文件提供「測試主機名稱 ↔ `docker-compose.yml` 服務名稱」對照表，至少涵蓋
   `src/single.test.ts:548,550` 與 `src/multi.test.ts:319-321,326-328` 的 8 個 hostname。
4. 文件說明測試需要 Redis，並指出 3 個 stub 測試檔（`src/quorum.test.ts`、
   `src/acquire-expiration.test.ts`、`src/extend.test.ts`）不需要 Redis，但現行
   `yarn test` 會一次執行全部 5 檔（`package.json:67`），故無官方無 Redis 子集入口。
5. 文件標明描述基準為 `software-factory` 的某個 commit SHA，且每項可驗證結論附
   `檔案:行號` 出處。
6. `yarn lint`（prettier + eslint）在改動後通過——新增的 `.md` 也在 prettier 檢查範圍內
   （`package.json:64`）。

**非目標（建議另開工作項）**：

- 修正 `.travis.yml:8` 的失效 `test-ci`、`.coveralls.yml:1`、README badge（`README.md:1`）。
- 新增 lockfile 或 `test:unit` script（`package.json:62-71`）。

---

## 10. 驗證方式與本報告的限制

- 本報告每項結論均附 `檔案:行號`（或明確的 git／API 指令），可直接以第 6 節列出的 `grep`/`sed`
  指令重現。
- **未執行 `yarn test`**：本次為 `agent-analyze`（不得變更程式碼／測試／設定），且依 Issue
  「已知問題：不得在沒有 Redis 的環境執行測試」與 DoD「不跑需外部服務的 E2E」。工作樹亦無
  `node_modules`，`yarn test` 之前還需 `build`。
- 可重現的驗證命令（需 Docker，未在本 run 執行）：
  `docker compose run --rm --no-TTY builder yarn lint` →
  `docker compose run --rm --no-TTY builder yarn build` →
  `docker compose run --rm --no-TTY runner yarn test`（對照 `.github/workflows/ci.yml:21-26`）。
- 行號基準皆為 `software-factory@8371226056b85ca70632e91ec9b0d5236336f41b`；若分支前進，行號需重新對照。
- 本 checkout 為 shallow clone（`git log` 僅 1 筆），「領先 25 個 commit」取自 GitHub compare API，
  非本地 `git log` 計算。
