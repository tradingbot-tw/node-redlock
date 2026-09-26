// Redlock 可執行規格：具體實例（ADR-018 模型階段）
//
// 每個模組固定一組常數，供 verify.yml 以 `--main <module>` 執行。
// 常數需在 verify.yml 附 domain_justification（程式碼檢查位置或「程式未限制」）。
//
// 節點數 N：src/index.ts:207-211 只要求 clients.size != 0，未限制上限或奇偶，
//   故涵蓋邊界 1 與 2/3/4（偶、奇）。
// 資源數：src/index.ts 對 resources 長度未做檢查，故涵蓋 1 與 2。
// DURATION：src/index.ts:302-304 只檢查整數，未限制最小值；涵蓋邊界 1 與一般值 4/200。
// AUTO_EXTENSION_THRESHOLD：src/index.ts:700-704 要求 <= duration - 100。

module n1 {
  import model(
    N = 1,
    CLIENTS = Set(1, 2),
    RESOURCES = Set(1),
    DURATION = 4,
    AUTO_EXTENSION_THRESHOLD = 0
  ).* from "./model"
}

module n2 {
  import model(
    N = 2,
    CLIENTS = Set(1, 2),
    RESOURCES = Set(1),
    DURATION = 4,
    AUTO_EXTENSION_THRESHOLD = 0
  ).* from "./model"
}

module n3 {
  import model(
    N = 3,
    CLIENTS = Set(1, 2),
    RESOURCES = Set(1),
    DURATION = 4,
    AUTO_EXTENSION_THRESHOLD = 0
  ).* from "./model"
}

module n4 {
  import model(
    N = 4,
    CLIENTS = Set(1, 2),
    RESOURCES = Set(1),
    DURATION = 4,
    AUTO_EXTENSION_THRESHOLD = 0
  ).* from "./model"
}

module n3r2 {
  import model(
    N = 3,
    CLIENTS = Set(1, 2),
    RESOURCES = Set(1, 2),
    DURATION = 4,
    AUTO_EXTENSION_THRESHOLD = 0
  ).* from "./model"
}

module n3MinDuration {
  import model(
    N = 3,
    CLIENTS = Set(1, 2),
    RESOURCES = Set(1),
    DURATION = 1,
    AUTO_EXTENSION_THRESHOLD = 0
  ).* from "./model"
}

module n3Using {
  import model(
    N = 3,
    CLIENTS = Set(1, 2),
    RESOURCES = Set(1),
    DURATION = 200,
    AUTO_EXTENSION_THRESHOLD = 50
  ).* from "./model"
}
