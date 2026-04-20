# CLI Pulse iOS v1.9.2 — 开发计划书

> **目标平台**: iOS / iPadOS (macOS v1.9.2 已于 2026-04-18 提交审核, iOS 需要独立 build)
> **起点**: iOS 1.9.1 Ready for Distribution; ASC 上 1.9.2 "Prepare for Submission" 已占位, iPhone 6.9" 截图已上传
> **日期**: 2026-04-18
> **Codex Review**: ✅ passed 2026-04-18, 关键修正已合并到下方

---

## 一、背景与定位

macOS 1.9.2 核心变更是 **Provider Settings 体验**(Test connection + show/hide API key + Keychain autofill 修复 + 窗口独立化)。这些全是 macOS-only 代码路径,iOS 代码库没触到。

如果 iOS 1.9.2 只换截图不换 build,ASC 不允许通过(Prepare for Submission 需要 build)。所以 iOS 需要独立的有实质内容的 build,且应该是 iOS-native 的价值:

当前 iOS 已具备: Widgets(home + lock + watch complication)、iPad NavigationSplitView、Export CSV、Onboarding card、 Cost Section、Subscription Utilization、Sparkline activity timeline。

**未覆盖**: App Intents / Shortcuts / Siri、Live Activity + Dynamic Island、Interactive Widgets (iOS 17+ button)、Control Widget (iOS 18+)、iPadOS 布局细节。

---

## 二、范围 (Scope)

### 核心 — MUST ship (post-codex: scope 收紧)

**A. App Intents + Siri Shortcuts** (reduced)
- 2 个 AppIntent(OpenTab 暂时砍掉 — 需要 URL routing + CFBundleURLTypes,新工作量):
  1. `GetStatusIntent` — 返回摘要(usage / cost / sessions / alerts today),Siri + Shortcuts 可见
  2. `GetProviderQuotaIntent(provider: enum)` — 返回指定 provider 的剩余配额
- 文件位置(codex 指正):`CLI Pulse Bar iOS/Intents/` — **不放 CLIPulseCore**(它是多平台包,会污染 macOS target)
- 数据源: 复用 `WidgetDataProvider.loadCachedData()` 的 App Group cache;若 cache stale 提示用户"Open CLI Pulse to refresh"
- 启动时调 `CLIPulseShortcuts.updateAppShortcutParameters()`
- Siri phrase 本地化 EN(必须),JA/ZH 二期

**B. Interactive Widget refresh button (iOS 17+)**
- 在 `UsageOverviewWidget` medium/large 加 refresh button
- `RefreshWidgetIntent: AppIntent`(**不是** LiveActivityIntent — codex 指正)
- 文件位置: `CLI Pulse Bar iOS/Intents/RefreshWidgetIntent.swift`,target membership = iOS app + Widgets(两处都勾)
- `perform()` 返回时 WidgetKit 自动刷 timeline;`reloadTimelines` 作可选保险
- 无 iOS 16 fallback(deployment target 已是 17.0 — codex 确认)

**C. iPad Dashboard polish**
- iPad metrics grid 改 `GridItem(.adaptive(minimum: 180))`,避免孤立卡
- `iPadSplitView` 设 sidebar `.navigationSplitViewColumnWidth(260)`
- 配合 user 抓 iPad 6 张截图,尺寸 2064×2752 (13" iPad Pro) — 2048×2732 也被 ASC 接受(codex 指正,12.9" 未 deprecated)

### 砍掉(codex 建议)

**D. Live Activity** — CUT
理由: 无 ActivityKit 代码基础、无 `NSSupportsLiveActivities`、无 activity lifecycle 管理,扩展 review surface 风险大,收益低。留给 v1.9.3 或 v2.0。

### 明确 NOT in scope

- 任何 macOS 代码修改(macOS 1.9.2 已在审,避免触发 re-submission)
- Control Widget (iOS 18+ only) — 延后 v2.0
- 新增 provider / 新的数据源
- 后端 / Supabase schema 变更
- Android / watchOS 改动

---

## 三、阶段规划 (stage-gated)

每个 Stage 结束都:build 通过 + 单测通过 + 手测通过 + 我自己 review + Codex review

### Stage 0 — pre-flight (5 min)
- [ ] Read 当前 `CLIPulseCore/AppState.swift` 的 Tab enum、WidgetDataProvider 数据格式
- [ ] 确认 Widgets target deployment target ≥ iOS 17 (interactive button 需要)
- [ ] 确认 App Group identifier(复用 widgets 已有的)

### Stage 1 — App Intents infra (45 min)
- [ ] 新增 `CLI Pulse Bar iOS/Intents/` 目录(**iOS app target only**)
- [ ] `GetStatusIntent.swift` — `AppIntent`, returns `IntentDialog` + `ProvidesDialog` UI snippet
- [ ] `GetProviderQuotaIntent.swift` — 带 `@Parameter` enum provider 的 `AppIntent`
- [ ] `CLIPulseShortcuts.swift` — `AppShortcutsProvider` with EN phrases(JA/ZH 二期)
- [ ] 在 `CLIPulseApp_iOS.swift` `onAppear` 里调 `CLIPulseShortcuts.updateAppShortcutParameters()`
- [ ] 单测: intent perform 逻辑(mock App Group cache → expect formatted result)
- [ ] 手测: Shortcuts.app 能看到 intent;Siri "CLI Pulse status" 能回话

### Stage 2 — Interactive widget (30 min)
- [ ] `CLI Pulse Bar iOS/Intents/RefreshWidgetIntent.swift` — 纯 `AppIntent`,target membership 勾 iOS app **和** Widgets
- [ ] `UsageOverviewWidget` medium 尺寸底部加按钮 `Button(intent: RefreshWidgetIntent())`
- [ ] `perform()`: 从 App Group cache 重读 → 写回(或触发 phone 侧 reconcile)
- [ ] 手测 simulator: widget 上 refresh 按钮可见、按下后 lastUpdated 时间戳变化

### Stage 3 — iPad polish + screenshots (20 min)
- [ ] `iOSOverviewTab.metricsGrid()` iPad 分支改用 `GridItem(.adaptive(minimum: 180))`
- [ ] `iPadSplitView` 设 `.navigationSplitViewColumnWidth(220)` sidebar, 或用 `.fixed`
- [ ] iOS Simulator 跑 iPad Pro 13",手动抓 6 张截图(用 simctl io screenshot),裁到 2064×2752
- [ ] 用 Python composer 生成 1290×2796 风格的 iPad 变体(canvas 2064×2752,字体和 margins 按比例放大)
- [ ] 上传 ASC iPad 12.9" / 13" section

### Stage 4 — version bump + build + upload (15 min)
- [ ] `MARKETING_VERSION` 1.9.1 → 1.9.2 (iOS target only, macOS 已是 1.9.2)
- [ ] `CURRENT_PROJECT_VERSION` bump build number
- [ ] `scripts/build-appstore.sh` 或 Xcode Organizer archive+upload
- [ ] ASC 上选 iOS build,填 "What's New",Add for Review
- [ ] 更新 CHANGELOG / 写 release notes

---

## 四、"What's New" 文案 (iOS)

**≤170 chars**:
```
Ask Siri for your status or provider quota. Widgets get a one-tap refresh button. Smoother iPad dashboard layout.
```

**Bullets**:
- **Siri & Shortcuts**: ask "CLI Pulse status" or get Claude/Codex/Gemini quota hands-free
- **Interactive widget**: tap refresh right on your Home Screen
- **iPad polish**: tighter dashboard layout, better sidebar width

---

## 五、风险与决策点

| 风险 | 缓解 |
|------|------|
| AppIntent 编译到 macOS target 污染 | 文件 **完全放 iOS app target membership**,不放 CLIPulseCore(多平台包);RefreshWidgetIntent 勾 iOS app + Widgets |
| 宣传中 Siri/Shortcuts 但 Shortcuts.app 看不到 intent | Stage 1 手测必过:打开 Shortcuts.app,搜 "CLI Pulse",两个 intent 必须可见 |
| Interactive button perform() 空操作,按下无反应(review 拒) | Stage 2 手测必过:按 refresh,widget 的 lastUpdated 字符串必须变化 |
| iPad screenshot 尺寸和 ASC 不符 | 13" iPad Pro: 2064×2752 **或** 2048×2732 都接受 |
| 冲击 macOS 1.9.2 在审 | iOS target 独立,不改 macOS target 和 `CLIPulseCore` 共用代码;intents 全放 iOS 目录 |

**决策点 A (Stage 1 完)**: AppIntent 必须在 Shortcuts.app 可见、Siri 能触发 → 否则不进 Stage 2,砍 A 只做 B+C

**决策点 B (Stage 2 完)**: widget 按钮必须真正刷数据 → 否则砍 B,只做 A+C

---

## 六、Review gates

每 Stage 完成后:
1. `xcodebuild -scheme "CLI Pulse Bar iOS" build` 通过
2. `swift test` (CLIPulseCore 包) 通过
3. 我自己读 diff,检查 `#if os(iOS)` / deployment target / App Group 访问
4. **Codex review**: 提交 diff + PR description,等 codex verdict
5. 问题解决后再进下一 stage

Final build 前最后一次 Codex + 我自己双 review 整体 diff。

---

## 七、Out-of-band 事项

- iPad 截图由 user 自己在 simulator 上抓(方案已对齐 2026-04-18)
- ASC submission 走 Chrome MCP
- 不改版本号字符串之外的任何 config/entitlement/bundle identifier
