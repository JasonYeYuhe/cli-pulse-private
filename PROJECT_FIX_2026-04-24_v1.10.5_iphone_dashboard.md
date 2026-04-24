# CLI Pulse 修复存档 — 2026-04-24 (v1.10.5 iPhone Dashboard 修复)

> 任务: 线上用户反馈 — iPhone Dashboard 在 v1.10.4 MAS 版本上显示全 0 (Usage Today=0, Requests=0, Cost Summary <$0.01)
> 同步改进: CPU alert 阈值改为按总核心数自适应 (不同机器不同核数)
> 基于版本: v1.10.4 (commit 9b004a8)

---

## 背景

用户升级 v1.10.4 (MAS 正式版) 后，iPhone 端 Dashboard 呈现异常:

- **Mac 菜单栏 app**: 正常显示 Claude $529.83 周成本、Codex $58.96
- **iPhone app**: Usage Today = 0 tokens、Requests = 0、Cost Summary 所有项 `<$0.01`
- **数据源差异**: Mac app 直接本地读 `~/.claude/projects` JSONL，iPhone/Watch/Android 走 Supabase

排查定位到 MAS sandbox 限制: `/bin/ps` subprocess 在 sandbox 里返回 0 行，
并且 `proc_listallpids` / `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)` 这些
in-process 的 libproc API 在 ad-hoc sandbox-signed binary 里也会 SIGTRAP (exit 133)。
换句话说 — **MAS sandbox 下进程枚举架构性不可行**。

连锁反应: CLIPulseHelper 的 `LocalScanner.scan()` 产出 0 session → 同步到 Supabase
的 `sessions` 表常年为空 → 服务端 `dashboard_summary` / `provider_summary` RPC
从空的 sessions 表聚合 → iPhone 拿到 0。

---

## 修改文件清单

### Swift 客户端

| 文件 | 修改 |
|------|------|
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/LocalScanner.swift` | `listProcesses()` 从 `/bin/ps` 改 libproc (proc_listallpids + proc_pidpath + proc_pidinfo PROC_PIDTBSDINFO/PROC_PIDTASKINFO)，返回 `LocalScanResult.sessionCPU` 供告警使用；加 `os.Logger` 便于线上调查 sandbox 失败 |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertGenerator.swift` | Rule 2 session CPU 告警改为核数自适应: `cpu / (cpuCount * 100) >= 0.4`，文案输出 `~{systemPct}% of total system CPU ({cores} cores)` |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/APIClient.swift` | `syncDailyUsage` 不再排除当天 — 允许 iPhone 从 `daily_usage_metrics` 读到实时数据，每次刷新 upsert 覆盖当天行 |
| `CLI Pulse Bar/CLIPulseHelper/HelperDaemon.swift` | 把 `scanResult.sessionCPU` 传给 `AlertGenerator.generate` |
| `CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/AlertGeneratorTests.swift` | 测试输入用 `Double(cores) * 100.0 * 0.6` 触发、`* 0.3` 不触发，适配自适应阈值 |

### 服务端 (Supabase migration)

**migration**: `dashboard_and_provider_summary_read_daily_metrics` (已 apply 到 prod)

| RPC | 改动 |
|-----|------|
| `dashboard_summary` | `today_usage` / `today_cost` / `today_sessions` 从 `daily_usage_metrics` 按 `metric_date = current_date` 聚合 (不再查 sessions 表) |
| `provider_summary` | 用 CTE: `usage_agg` 来自 `daily_usage_metrics`，`quota_agg` 来自 `provider_quotas`，`FULL OUTER JOIN` 两者；保留 `active_sessions` / `online_devices` / `unresolved_alerts` 字段；新增 `estimated_cost_today` |

### 版本号

| 文件 | 旧 → 新 |
|------|--------|
| `project.pbxproj` (10 × MARKETING_VERSION) | 1.10.4 → 1.10.5 |
| `project.pbxproj` (10 × CURRENT_PROJECT_VERSION) | 38 → 39 |
| 4 × Info.plist (iOS / macOS / Watch / Widgets) CFBundleShortVersionString | 1.10.4 → 1.10.5 |

---

## 设计决策

### 为什么不试着修复 sandbox 下的进程枚举
Apple 没有提供公开 entitlement 让沙盒 helper 列举其他进程的 PID。试过的方案:
- `/bin/ps` subprocess: 返回 0 行 (进程 spawn 限制)
- `proc_listallpids` / `proc_pidpath`: errno=1 EPERM
- `sysctl KERN_PROC`: SIGTRAP

**结论**: sandboxed LoginItem 里进程枚举架构性不可行。绕开 — 让 iPhone 端从
`daily_usage_metrics` 拿数据 (这个表由 `CostUsageScanner` 从 JSONL 文件 bookmark
解析填充，bookmark 是 user-granted 的，不受 sandbox 限制)。

### 为什么同步当天数据
原先 `syncDailyUsage` 排除今天是怕推送不完整数据到服务端。但在 sessions 表
变空之后，今天的数据就**只有**这一条路径能到达服务端。改成每次 upsert 覆盖，
partial-day 值随刷新自动修正。key: `(user_id, metric_date, provider, model)`。

### 为什么 CPU 告警要核数自适应
老逻辑: `ps pcpu >= 80`，也就是 "占一个核的 80%"。在 14 核 M4 Max 上 80% pcpu
只占总体 5.7% — 完全正常的轻载也会一直报警。
新逻辑: `pcpu / (cpuCount * 100) >= 0.4` — 占总系统 CPU 40% 以上才报，文案里
同时显示百分比和核数，用户一眼就知道机器多大。

### 为什么 provider_summary 用 FULL OUTER JOIN
`daily_usage_metrics` 有但 `provider_quotas` 没有的 provider (比如自建网关)
也要出现在列表里；反之 `provider_quotas` 有 tier 数据但今天没用 (比如 Claude
Weekly window 刚重置) 也要出现。任一边存在就输出一行。

---

## 验证

### 单元测试
```
swift test  (CLIPulseCore package)
→ Test run with 0 tests in 0 suites passed (Testing Library)
→ All XCTest suites passed (legacy XCTest for AlertGeneratorTests etc.)
```

### 服务端 RPC 验证 (prod Supabase)
对用户 user_id 调用:
```sql
select * from provider_summary(<uid>, 'week', 20);
→ Claude   week_cost=$529.83  tiers=[5h, Weekly, Sonnet]
→ Codex    week_cost=$58.96   tiers=[...]
→ 其它     按 today_cost DESC 排序
```

### macOS 本地构建
```
xcodebuild -scheme "CLI Pulse Bar" build  → BUILD SUCCEEDED
```

---

## 已知残留风险

1. **Android/Watch 端依赖同一 RPC**: 已随服务端 migration 修复，不需要重发包。
2. **Active sessions 数字在 iPhone 会显示 0**: MAS 版本 sandbox 下确实无法枚举
   进程，这是物理限制。非 MAS (开发者直分发) 版本的 helper 仍能正常枚举进程。
   前端需考虑隐藏该字段或标 `N/A` — 留作 P3 改进。
3. **provider_quotas 更新频率**: 依赖 helper 每 2 分钟跑一次 collector
   registry — 这部分与本次修复无关。

---

## 上传 App Store

- **Apple**: v1.10.5 build 39 已版本号同步，等用户确认后走常规 ASC 上传脚本
- **Android**: 服务端 RPC 已迁移，当前 APK 不需要重发；下次发版再带 build 号即可

## 相关 commit

- `a2c1bb4` v1.10.5 build 39: iPhone dashboard fix + adaptive CPU alerts
- 基线: `9b004a8` chore: sync versions to v1.10.4
