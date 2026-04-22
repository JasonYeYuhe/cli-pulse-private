# CLI Pulse 修复存档 — 2026-04-22 (P2-8 Sentry 接入)

> 任务: plan 里 P2-8 — 线上 crash 可见性
> 集成 SDK: sentry-cocoa 9.10.0 / sentry-android 8.23.0
> Sentry 组织: jason-yeyuhe.sentry.io (3 个 project: apple-ios, apple-macos, android)
> 基于版本: v1.10.2 (commit adebf20)

---

## 背景

P2-8 在 plan 里长期 pending，风险: App Store 用户遇到 crash 我们看不见，
只有等 1 星 review 才知道。现在接入 Sentry 填补这个盲点。

---

## 修改文件清单

### Apple (iOS / macOS / watchOS) — 共用 sentry-cocoa

| 文件 | 修改 |
|------|------|
| `CLI Pulse Bar/CLIPulseCore/Package.swift` | 新增 sentry-cocoa (9.10.0+) 依赖 |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/SentryLogger.swift` | 新建 — DSN 读取 + beforeSend/beforeBreadcrumb 脱敏 |
| `CLI Pulse Bar/CLI Pulse Bar/Info.plist` | 新增 `SENTRY_DSN` (macOS project DSN) |
| `CLI Pulse Bar/CLI Pulse Bar/CLIPulseBarApp.swift` | `init()` 首行调用 `SentryLogger.start(platform: .macOS)` |
| `CLI Pulse Bar/CLI Pulse Bar iOS/Info.plist` | 新增 `SENTRY_DSN` (iOS project DSN) |
| `CLI Pulse Bar/CLI Pulse Bar iOS/CLIPulseApp_iOS.swift` | `init()` 首行调用 `SentryLogger.start(platform: .iOS)` |
| `CLI Pulse Bar/CLI Pulse Bar Watch/Info.plist` | 新增 `SENTRY_DSN` (复用 iOS project DSN) |
| `CLI Pulse Bar/CLI Pulse Bar Watch/CLIPulseApp_Watch.swift` | 添加 `init()` 调用 `SentryLogger.start(platform: .watchOS)` |

### Android — sentry-android-core

| 文件 | 修改 |
|------|------|
| `android/gradle/libs.versions.toml` | 新增 `sentry = "8.23.0"` 和 `sentry-android-core` library 条目 |
| `android/app/build.gradle.kts` | 添加 `BuildConfig.SENTRY_DSN` + implementation 依赖 |
| `android/local.properties` | 新增 `SENTRY_DSN=<android project DSN>` |
| `android/app/src/main/java/com/clipulse/android/util/SentryInit.kt` | 新建 — 初始化 + beforeSend/beforeBreadcrumb 脱敏 |
| `android/app/src/main/java/com/clipulse/android/CLIPulseApp.kt` | `onCreate()` 调用 `SentryInit.install(this)` |

### 文档

| 文件 | 修改 |
|------|------|
| `PRIVACY.md` | 新增 Sentry crash 报告数据行 + 详细说明 `sendDefaultPii=false` / IP scrub / beforeSend 脱敏 |

---

## 设计决策

### watchOS 复用 iOS project DSN
理由: 表手用户量极小，单独建 project 信号噪声比差。用 `platform_family: watchos`
tag 在 iOS project 里区分即可。

### tracesSampleRate = 0.0
理由: 只要 crash/error 可见性，不要性能追踪 (5k events/月 free tier 够用)。

### 自定义 beforeSend 脱敏 (两层防御)
除了 Sentry dashboard 开启 `Require Data Scrubber` + `Enhanced Privacy` +
`Prevent IP Storage`，在客户端多做一层兜底:

- **字段名匹配**: `password / secret / token / apikey / bearer /
  supabase / claude_api / anthropic / codex / openai / gemini / dsn /
  device_token / pairing / refresh_token / access_token / id_token /
  keychain` 子串命中直接 `[scrubbed]`
- **正则脱敏**: JWT (`eyJ...`)、OpenAI/Anthropic key (`sk-...`)、Stripe
  key (`sk_live_...`)、`Bearer <token>`
- **路径脱敏**: `/Users/<name>/...` → `/Users/[user]/...`
- **User 对象**: email / ipAddress / username 清零

同时应用于 event.exceptions[*].value、event.message、breadcrumb.message 和
所有 data/tags/extra 字段。

### DSN 存储方式
- Apple: Info.plist 明文（DSN 本身是公开信息，只能写入不能读取）
- Android: `local.properties` → `BuildConfig.SENTRY_DSN`（不进 git）

### 没做的事
- Python helper (`helper/cli_pulse_helper.py`) — 跳过。出问题量极小，必要时再加
- Supabase edge functions — Deno SDK 仍 beta，跳过
- 自动上传 dSYM / ProGuard mapping — 手动上传就够

---

## Sentry Dashboard 配置

已在 `jason-yeyuhe.sentry.io` organization 级别开启:

- [x] Enhanced Privacy
- [x] Require Data Scrubber
- [x] Require Using Default Scrubbers
- [x] Prevent Storing of IP Addresses
- [x] Allow Shared Issues → OFF
- [x] Allow Join Requests → OFF

Global Sensitive Fields 追加 22 个 CLI Pulse 特有字段名。

---

## 验证

### 已验证
- [x] macOS: `xcodebuild -scheme "CLI Pulse Bar" build` → SUCCEEDED
- [x] iOS Simulator: `xcodebuild -scheme "CLI Pulse iOS" build` → SUCCEEDED
- [x] watchOS Simulator: `xcodebuild -scheme "CLI Pulse Watch" build` → SUCCEEDED
- [x] Android: `./gradlew :app:assembleDebug` → BUILD SUCCESSFUL

### 待用户手动验证 (运行时)
下一次在各平台真实运行时，可手动触发一次测试 crash 验证 Sentry 收到事件:

```swift
// 随便在一个按钮里加
SentrySDK.capture(message: "test crash from macOS build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?")")
```

```kotlin
// Android
io.sentry.Sentry.captureMessage("test from android")
```

然后打开 https://jason-yeyuhe.sentry.io/issues/ 看事件是否带正确的
`platform_family` tag 且敏感字段被 `[scrubbed]`。

---

## 影响

- **Bundle 大小**: iOS/macOS ~1-2 MB, Android ~600 KB
- **启动耗时**: SentrySDK.start 主线程阻塞 < 50ms, 后台线程上报
- **隐私叙事**: PRIVACY.md 已明确披露 Sentry，不再说"无第三方分析 SDK"
