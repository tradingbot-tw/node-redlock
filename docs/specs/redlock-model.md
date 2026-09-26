# Redlock Quint 模型（as-is）— 建模範圍與對照

本文件說明 `specs/redlock/model.qnt`（as-is 模型，ADR-018 模型階段）的範圍、
抽象決定與來源對照。不變量定義於已核准的 `specs/redlock/invariants.qnt`，
本模型不修改 `src/`。

## 檔案

| 檔案 | 內容 |
| --- | --- |
| `specs/redlock/source.md` | 規格來源快照（CI 寫入，不變量逐字引用） |
| `specs/redlock/invariants.qnt` | 已核准的 `INV_*` 不變量（未修改） |
| `specs/redlock/model.qnt` | as-is 模型：`init`、動作、`WIT_*` 情境 witness |
| `specs/redlock/instances.qnt` | 具體常數實例（n1/n2/n3/n4/n3r2/n3MinDuration/n3Using） |
| `specs/redlock/verify.yml` | 模型檢查清單與常數 domain_justification |

## 來源對照（`src/index.ts`，本 repo 現況）

| 模型元素 | 程式位置 | 說明 |
| --- | --- | --- |
| `voteAcquire` / acquire 的 key 語意 | `src/index.ts:12-27` | `ACQUIRE_SCRIPT`：任一 key 已存在即回 0；否則對全部 key set 並回 key 數 |
| `voteExtend` | `src/index.ts:29-44` | `EXTEND_SCRIPT`：`get(key)==value` 才更新 TTL |
| `voteRelease` | `src/index.ts:46-58` | `RELEASE_SCRIPT`：`get(key)==value` 才刪除 |
| `startAcquire` / acquire 成功 | `src/index.ts:297-341` | 僅檢查 duration 為整數；`drift=round(driftFactor*duration)+2`；quorum 成功即回 `Lock` |
| `startRelease` | `src/index.ts:350-364` | 先將 `expiration` 設 0，再對所有 node 執行 release |
| `startExtend` / extend 成功 | `src/index.ts:369-409` | `expiration < now` 才擋；成功後 invalidate 舊 Lock 並回傳新 Lock |
| `autoExtend` | `src/index.ts:661-769` | `using` 依 `automaticExtensionThreshold` 排程自動延長 |
| `vote*` 的 quorum 判定 | `src/index.ts:473-550` | 逐票累計；`votesFor == quorumSize` 或 `votesAgainst == quorumSize` 才 resolve |
| `crash` / `recover` | `src/index.ts` 無對應 | node 可用性；重啟不遺失 key（部署前提） |

## 抽象決定

- **單一邏輯時鐘 `now`**：不建模跨 process 時鐘漂移與牆鐘跳躍（Issue 範圍）。
- **逐資源**：`acquire` / `extend` / `release` 以單一 `(client, resource)` 的嘗試狀態建模；
  單一 node 上多個 key 的原子性不在模型內，跨資源原子性亦不在範圍（Issue 範圍）。
- **重試**：`_execute` 對相同 value 的重試回圈未逐一建模；一次嘗試失敗後模型允許再發起
  新嘗試（新 token）。retryCount / retryDelay / retryJitter 未建模。
- **`using`**：只建模自動延長時序（`autoExtend`）；routine 內容、`AbortSignal` 與其傳遞
  為外部程式碼，不在模型內。
- **崩潰**：只改 `nodeUp`；key 不因重啟遺失。規格要求崩潰實例至少 max TTL 不可用，屬
  部署前提，不作為發現。

## 如何執行

```bash
npx quint typecheck specs/redlock/instances.qnt
npx quint run specs/redlock/instances.qnt --main n3 \
  --invariant INV_mutualExclusion --witnesses WIT_twoClientsContend \
  --max-steps 24 --max-samples 15000
```

`verify.yml` 的 check 由 factory-run 重新執行並判定；本模型不宣告預期結果。

## 不涵蓋（刻意留白）

- 跨資源原子性；單一 node 上多 key 的 all-or-nothing 語意。
- `_execute` 的實際重試次數、延遲與 jitter。
- `using` routine 的行為與 abort 後的續行。
- 時鐘漂移、牆鐘跳躍、`fsync` / AOF / 崩潰恢復時序。
- `src/index.ts` 的錯誤型別、事件、序列化與連線細節。

## 未決事項

見 PR 描述的「未決事項」章節；摘要如下（詳見該處）：

1. `issuedAt` 在 `extend` 時應取「延長完成」或「延長開始」。
2. 重試是否必須沿用同一 token 才能覆蓋 token 重用缺陷。
3. 逐資源模型是否足以代表單一 node 上多 key 的原子性。
4. `using` routine / AbortSignal 是否需納入。
