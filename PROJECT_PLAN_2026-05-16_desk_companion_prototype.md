# 桌面伴侣小机器人 — 完整规划方案

## Context（为什么做这个）

CLI Pulse 现在是一个纯软件产品：监控 Claude Code / Codex / Gemini 等 AI 编程
agent 的会话状态、花费、配额、告警，跨 macOS / iOS / watch / Android，靠
Supabase 后端同步。

痛点：开发者在跑 agent 的时候，注意力在别处（开会、看文档、离开工位），
经常错过 "agent 跑完了"、"agent 卡在要审批"、"今天烧的钱超预算了" 这些时刻。
手机/菜单栏是被动的、要主动去看。

机会：做一个**放在桌上的实体伴侣设备**，把这些状态"推到你眼前"——一眼能看到
agent 在不在跑、要不要你审批、今天烧了多少钱。它是 CLI Pulse 的硬件延伸，
复用现有 Supabase 后端和账号体系。第一阶段做纯氛围显示屏验证概念，之后演进
成有表情、会动的小机器人。目标：先做出原型，再小批量（几十到几百台）试卖给
社区/早期用户。

用户已确认的方向：
- **定位**：先和 CLI Pulse 联动，架构预留未来扩展成通用桌面伴侣的空间
- **交付**：本次只要完整规划方案，不写代码
- **形态**：原型从纯氛围显示屏起步 → 后续加表情/动作
- **量级**：原型 → 小批量试卖（不是一上来就做全认证的量产消费电子）

---

## 一、产品概念（设备做什么）

一台巴掌大、桌面摆件级别的设备，常驻显示当前 AI 编程 agent 的"生命体征"：

| 信号 | 氛围屏阶段表现 | 表情机器人阶段表现 |
| --- | --- | --- |
| 没有活动会话 | 待机表盘 / 时钟 / 慢呼吸光 | 打瞌睡、闭眼 |
| 有会话在跑 | 进度脉冲、provider 图标、token 计数 | 专注脸、跟随进度的小动作 |
| **需要你审批/输入** | 醒目橙色闪烁 + 蜂鸣 | 惊讶脸 + 转头看你 + 提示音 |
| 会话跑完 | 绿色 + "DONE" + 本次花费 | 开心脸 / 庆祝动作 |
| 今日花费 / 配额 | 数字 + 进度环，超阈值变红 | 配额低时担忧脸 |
| 严重告警 | 红色警示 + 标题滚动 | 警觉/不安表情 |

核心交互（按阶段递进）：
- **氛围屏阶段**：单个物理按键（确认/静音/切换视图）+ 屏幕。无机械结构。
- **表情阶段**：屏幕动画表情 + RGB 灯 + 蜂鸣/小喇叭 + 1–2 个舵机（点头/转头）。
- **未来通用化**：把"agent 状态"做成众多 widget/skin 之一，设备本身可显示
  天气/番茄钟/通知等，agent 联动只是首发杀手级场景。

---

## 二、硬件技术选型（原型 → 小批量）

推荐**两条腿走路**，先用成熟开发套件做"能 demo 的原型"，再收敛到可小批量的
自研板。

### 阶段 A：概念验证原型（1–3 台，2–4 周）

最快出东西，优先选生态成熟、有现成圆形/方形屏的整机模组：

- **主控 + 屏一体推荐**：ESP32-S3 + 圆形/方形 IPS LCD 一体开发板
  （如 LILYGO T-Display 系列、Waveshare ESP32-S3 圆屏、M5Stack Dial/Core
  系列）。带 Wi-Fi、足够跑 TLS + JSON + LVGL UI、有外壳或易 3D 打印。
- 备选：**Raspberry Pi Zero 2 W + 小型 DSI/SPI 屏**——如果想跑全 Linux、做
  更复杂动画/语音，开发最省心，但功耗、成本、启动时间、量产一致性都更差。
  原型期可两条都试，量产倾向 ESP32-S3。
- 交互：一个轻触按键 + 蜂鸣器；外壳用 3D 打印（PLA/树脂）。
- 目标：验证"从后端取到状态 → 屏上正确渲染 → 审批/跑完能第一时间被人注意到"。

**选型理由**：ESP32-S3 生态对"联网小屏设备"是事实标准，LVGL 图形库成熟，
功耗低可长期通电待机，单价低（模组级 ¥30–80），量产链路清晰。

### 阶段 B：表情/会动版本原型

在阶段 A 主控基础上增加：

- 更大/更高刷新率屏（做流畅表情动画），或双屏做"眼睛"。
- WS2812 RGB 灯环（情绪光）。
- I2S 小功放 + 喇叭（提示音/简单语音）。
- 1–2 个微型舵机（点头/转头），配独立电源轨避免主控掉电。
- 可选：PIR/距离传感器（有人靠近才"醒来"，省电 + 增加灵性）。

### 阶段 C：小批量自研硬件（几十~几百台）

- 自研 PCB：ESP32-S3 模组 + 电源管理 + 屏 FPC 座 + 按键/灯/喇叭/舵机接口 +
  USB-C 供电。打样用嘉立创/JLCPCB 这类一站式 PCBA。
- 外壳：3D 打印小批量，或硅胶/注塑（视量决定，几十台用打印/手板，过百台
  考虑低成本模具或 CNC）。
- 一致性、烧录夹具、出厂测试脚本（见第六节产线）。

### 关键约束（贯穿全程）

- 设备物理暴露：放别人桌上，flash 可被读。**不能存用户主密码/长期高权限
  令牌**——必须用可吊销的、最小权限的设备级凭据（详见第四节后端集成）。
- 必须 HTTPS TLS1.2+；只能轮询（后端目前无 Realtime/无 Apple 之外推送）。
- 待机功耗要低（常年插电摆件，建议 < 1W 待机）。

---

## 三、产品体验与固件分层（概览，细节见第四节）

设备固件分四层：

1. **配网与配对层**：首次上电进 AP/BLE 配网，输入 Wi-Fi，扫码/输入配对码
   绑定到用户 CLI Pulse 账号，拿到设备级凭据并存入 flash。
2. **数据层**：周期性一次 HTTPS 调用拉取"设备快照"（一个聚合端点，见第四
   节），自适应轮询（有活动会话时加快）。
3. **渲染层**：把快照映射到 UI 状态机（待机/运行/需审批/完成/告警），
   LVGL 驱动屏幕 + 灯 + 声音（+ 后续舵机）。
4. **运维层**：OTA 固件更新、离线降级（断网显示"离线"而非乱渲染）、
   出厂自检。

第四节给出每层的具体方案：认证路径、聚合快照端点 JSON 契约、近实时信号、
固件状态机、所需的最小后端改动。

---

## 四、后端集成设计

设计原则：设备尽量"薄"，所有业务判断放后端；Phase 1 后端改动压到**最小
（仅一个新迁移文件，零新表/零新边缘函数/零 schema 变更）**。

### 4.1 设备认证路径（推荐：复用 helper 配对 + 只读化）

复用现有 `register_helper` 配对机制和 `helper_secret`，但作为**只读消费端**：

- 设备配对时传 `p_device_type = 'DeskCompanion'`，走和 helper 完全相同的
  配对码流程（`register_helper`，匿名 key + TLS），拿回
  `{device_id, user_id, helper_secret}`，secret 服务端只存 sha256。
- 新增的快照 RPC 在现有 hash 校验之外**额外要求 `devices.type =
  'DeskCompanion'`**，且该 RPC **只读、无写入 payload**。即使 flash 被 dump，
  泄露的也只是"这一个用户的氛围状态、只读"——不能调 `helper_sync`、
  不能远程审批（远程控制由 `remote_control_enabled` 独立门控，默认关）。
- **吊销直接复用现有能力**：用户在 iOS/Android app 的设备列表里删除该设备
  （删 `devices` 行，现有 `unregister_desktop_helper`），下一次轮询凭据即失效。
  设备也会自动出现在现有设备列表/在线状态 UI，零新增 UI。

为什么不用 user JWT：MCU 无法管理 OAuth/PKCE + 刷新令牌，且长期 JWT 放暴露
flash 上比设备级只读 secret 更危险。

### 4.2 聚合"设备快照"端点（新增一个 SECURITY DEFINER RPC，不用边缘函数）

数据全在 Postgres，RPC 是单次最低延迟 DB 往返、可复用现有聚合 SQL、和
`helper_heartbeat` 同一套 secret 鉴权；边缘函数在本仓库只用于对外推送。

- **新函数**：`public.desk_snapshot(p_device_id uuid, p_helper_secret text,
  p_user_today date default null) returns jsonb`
- **文件**：新建迁移 `backend/supabase/migrate_v0.48_desk_companion_snapshot.sql`
  （函数前导/grant 镜像 `helper_rpc.sql` 现有写法，`grant execute ... to anon`）。
- **鉴权**：内联 `select user_id from devices where id=p_device_id and
  helper_secret=encode(digest(p_helper_secret,'sha256'),'hex') and
  type='DeskCompanion'`；NULL 即 `raise exception`。顺带
  `update devices set status='Online', last_seen_at=now()`（复用现有在线 UI）。
- **组合（直接复制现有 SQL，不重新推导）**：
  - `today.cost/usage` ← 复制 `app_rpc.sql` 中 `dashboard_summary` 的
    `daily_usage_metrics` 聚合（按 `coalesce(p_user_today,current_date)`）。
  - 会话 ← `sessions where status='Running'`（上限 20，按 last_active_at desc），
    左连 `remote_permission_requests`（pending）得 `needs_approval`。
  - `pending_approvals` ← `remote_permission_requests` status='pending' 且未过期计数。
  - 告警 ← `alerts where is_resolved=false`，severity 排序 Critical>Warning>Info。
  - `quota` ← 复用 `provider_summary` 的 `provider_quotas` 投影，归约为最差
    provider 的 `min_remaining_pct` + `low`(<10%) + 最近 `reset_at`。
- **输出 JSON 契约**（扁平、定长键、数组有界，MCU 友好；含单一预计算
  `status` 枚举，固件零业务逻辑，只做 枚举→动画/颜色 映射）：

```jsonc
{
  "v": 1, "ts": "<server now>", "poll_after_s": 30,
  "status": "needs_approval",   // 优先级: needs_approval > alert_critical >
                                // quota_low > running > alert_warning >
                                // finished > idle
  "sessions": { "active": 3, "running": 2, "needs_approval": 1,
                "list": [ { "p": "Claude", "s": "approval" } ] },
  "pending_approvals": 1,
  "today": { "cost": 4.27, "usage": 812344 },
  "quota": { "low": false, "min_remaining_pct": 64, "reset_at": "<ts|null>" },
  "alerts": { "unresolved": 2, "top_severity": "Warning" },
  "device": { "online_devices": 1 }
}
```

- **轮询节奏（服务端建议 + 客户端钳制）**：空闲 `poll_after_s=30`；有
  Running 会话或 pending 审批时服务端返回 `poll_after_s=5`（快车道，审批
  ≤5s 触达，对桌面玩具足够"即时"）。客户端错误退避 5→10→30→60→120s
  + ±10% 抖动（防小批量设备同步惊群）；硬下限 5s、硬上限 120s（防恶意/bug
  服务端值打爆 MCU 或后端）。

### 4.3 近实时"需审批/已完成"信号

- **Phase 1（先上这个，零新基础设施）**：服务端自适应短轮询——`desk_snapshot`
  自己返回 `poll_after_s`，活跃时 5s，空闲 30s。审批/严重告警 ≤5s 触达。
  "会话跑完"由固件本地用前后两次快照的 `sessions.active` 下降推导，
  本地播 ~10s 庆祝动画→回 idle，**无需后端改动**。（可选：RPC 加
  `finished_recently`，让错过过渡那次轮询的设备也能庆祝——仍在 v0.48 同文件内。）
- **Phase 2（仅当延迟要做到亚秒级或要降活跃轮询负载才做）**：优先
  Supabase Realtime —— 设备用 secret 经一个 thin `realtime-auth` 边缘函数
  换取 1 小时短时 channel token（不长期存 JWT），保一条 WebSocket，断了
  回落 Phase 1 轮询。备选 SSE/MQTT 桥边缘函数（受边缘函数最长执行时间限制，
  Realtime 被否再考虑）。

### 4.4 固件状态机（ESP32 / Pi-Zero 级）

```
BOOT/INIT → (无 Wi-Fi/无凭据) → PROVISIONING (SoftAP+配网+输入配对码)
          → PAIRING (POST register_helper, type=DeskCompanion; 存加密 NVS)
          → POLL/SYNC (POST desk_snapshot) → RENDER (status→动画/灯/声;
            前后快照 diff 出 finished) → 按 clamp(poll_after_s,5,120)±jitter 重排
   分支:  401/403(被吊销) → UNPAIRED: 擦 NVS secret → 回 PROVISIONING
          5xx/超时/DNS → OFFLINE: 指数退避, 留最后一次好快照 + 陈旧点
          每 N 周期 → OTA_CHECK
```

- **凭据存储**：ESP32 用开启 flash 加密（eFuse 支撑）的专用 NVS 分区存
  `helper_secret` 等；Pi-Zero 用 0600 文件，原子写+rename+chmod（镜像
  `cli_pulse_helper.py` 的 `save_config` 语义）。绝不打印 secret。
- **OTA**：双 OTA 分区 + factory 回滚；快照响应**不**做 OTA 通道，单独每
  ~6h/开机 GET 一个静态版本化 manifest（Supabase Storage 公有对象），
  **Ed25519 验签**（公钥烧进固件）通过才切分区，自检（升级后一次
  `desk_snapshot` 200）失败自动回滚。固件版本走现有 `devices.helper_version`
  列和设备列表 UI，零新增后端。
- **离线/失败**：瞬时错误退避 + 保留最后好快照 + 陈旧点，绝不硬崩/重启；
  被吊销 → UNPAIRED 重新配对屏；JSON 用 SAX 解析进定长结构、忽略未知键
  （对 `v` 升级前向兼容）；硬件看门狗喂狗只在主循环；TLS 需大致正确时钟，
  配网后做一次 SNTP（SNTP 失败回退到 Date 头/`ts`）——这是固件侧需预算的风险点。

### 4.5 Phase 1 所需后端改动（最小，具体到文件）

仅**一个新迁移文件**，不动 `register_helper`/`helper_rpc.sql`/`app_rpc.sql`/
边缘函数/RLS/触发器/pg_cron：

1. 新建 `backend/supabase/migrate_v0.48_desk_companion_snapshot.sql`：
   `create or replace function public.desk_snapshot(...)`（`security definer
   set search_path = pg_catalog, public, extensions`，前导/grant 镜像现有
   helper RPC），body 即 4.2 的鉴权 + `update devices` + `jsonb_build_object`，
   today-cost / quota 数学**复制自** `dashboard_summary` / `provider_summary`
   以保持单一真相源；`grant execute ... to anon`。
2. 可选 `backend/supabase/rollback_v0.48.sql`：
   `drop function if exists public.desk_snapshot(uuid, text, date);`。

关键文件：
- `backend/supabase/migrate_v0.48_desk_companion_snapshot.sql`（新增，Phase 1 唯一后端改动）
- `backend/supabase/app_rpc.sql`（复制 today-cost / quota 聚合的真相源）
- `backend/supabase/helper_rpc.sql`（鉴权模式 + 函数前导/grant 范本）
- `backend/supabase/migrate_v0.26_remote_sessions.sql`（`remote_permission_requests` 列/索引）
- `backend/supabase/migrate_v0.38_unregister_desktop_helper.sql`（现有吊销路径，固件 UNPAIRED 依赖它）

---

## 五、分阶段路线图

| 阶段 | 目标 | 产出 | 大致周期 |
| --- | --- | --- | --- |
| P0 立项 | 砍清楚 MVP 信号集（建议只做：在跑 / 需审批 / 完成 / 今日花费 / 严重告警） | 一页需求 + 验收标准 | 几天 |
| P1 软原型 | 不碰硬件，先在 PC/手机上做一个"设备模拟器"跑通后端聚合端点 + 渲染逻辑 | 模拟器 + 后端最小改动上线 | 1–2 周 |
| P2 硬原型 A | ESP32-S3 圆屏整机，跑通配网/配对/轮询/渲染，能让人"第一时间注意到审批" | 1–3 台可 demo 实物 | 2–4 周 |
| P3 硬原型 B | 加表情动画 + 灯 + 声（可选舵机），打磨"灵性"和提示策略 | 表情版样机 | 3–5 周 |
| P4 小批量 | 自研板打样 + PCBA + 外壳小批量 + 出厂测试 + OTA 渠道 | 几十台可发货 | 6–10 周 |
| P5 试卖 | 定价、包装、配对引导、固件 OTA、退换/支持流程，社区/早期用户试卖 | 上架试卖 | 持续 |

每阶段都有明确"杀掉项目"的判据：P2 没法让人比看手机更快注意到审批 → 概念
不成立，停。

---

## 六、小批量量产与商务（试卖级，不做全认证量产）

- **BOM 与成本（阶段 C 估算，单台、量 ~100，仅供量级参考）**：
  - ESP32-S3 模组 ¥30–60｜屏 ¥20–60｜PCBA 其余料 ¥20–40｜外壳（小批打印/手板）¥30–80｜
    灯/喇叭/按键/舵机 ¥10–40｜包装 ¥10–20｜组装测试人工 ¥20–50
  - 物料合计大致 **¥150–350/台**，定价需覆盖物料 + 摊薄打样/模具 + 退换 +
    支持 + 平台抽成，试卖建议体验对标"开发者桌面玩具/效率周边"档位。
- **合规边界（试卖级，必须提前告知用户的现实）**：
  - 小批量试卖通常仍需基本电气安全意识；跨境/上架平台（如众筹、独立站）对
    无线设备可能要求 FCC/CE/3C 等认证——**本规划定位为"原型+小批量试卖"，
    认证按销售渠道与地区单列评估，不在本期范围内深做**。先以"开发者预览/
    工程样机"形式小范围试卖，规避早期合规重负。
- **渠道**：先 CLI Pulse 现有用户/社区（最精准）、独立站预售/小众众筹。
- **支持与售后**：OTA 修固件是关键护城河——硬件能力固定，体验靠固件持续迭代。
  必须 Day 1 就有 OTA + 设备远程吊销能力。

---

## 七、主要风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| 概念不成立（不比看手机强） | 致命 | P1 软模拟器 + P2 实物尽早验证"注意力捕获"，设杀项判据 |
| 设备凭据泄露（物理暴露） | 安全 | 设备级最小权限只读凭据 + 可即时吊销（第四节） |
| 后端无实时推送，审批提醒延迟 | 体验 | 自适应轮询 + Phase2 实时通道升级路径（第四节） |
| 硬件一致性 / 良率 | 成本/口碑 | 阶段 B 收敛 BOM，阶段 C 出厂自检脚本 + 烧录夹具 |
| 合规/认证拖慢上市 | 商务 | 定位工程样机/开发者预览小批量试卖，认证按渠道单列 |
| 固件长期维护负担 | 持续成本 | 强 OTA 体系；设备逻辑尽量薄，复杂度放后端聚合端点 |

---

## 八、验证方式（端到端）

- **后端最小改动**：在 Supabase 上 `psql`/查询编辑器验证新 RPC/迁移语法；
  跑 `python3 backend/supabase/ci_check_rpc_contract.py` 校验 RPC 契约；
  与现有 `dashboard_summary`/`provider_summary` 对账，数字一致。
- **设备模拟器（P1）**：脚本模拟一个设备，凭设备凭据轮询聚合端点，断言
  各状态（无会话/在跑/需审批/完成/告警）渲染分支正确；覆盖断网降级。
- **实物（P2+）**：真实跑一个 Claude Code 会话触发 needs-approval，掐表测
  "从触发到设备发出提醒"的延迟；与手机端做并排对比，确认设备更快被注意到。
- **OTA**：从旧固件 OTA 到新固件成功率与回滚验证。
- **安全**：吊销设备后，确认其凭据立即失效、再调用被拒。

---

## 九、本期建议的下一步（待你确认后执行）

1. 锁定 P0 的 MVP 信号集（建议：在跑 / 需审批 / 完成 / 今日花费 / 严重告警）。
2. ~~实施第四节的最小后端改动~~ ✅ 已完成：`backend/supabase/migrate_v0.48_desk_companion_snapshot.sql`
   （`desk_snapshot` RPC）+ `rollback_v0.48.sql`，已过全部 5 个后端 CI 契约校验。
3. 做 P1 设备模拟器跑通端到端，再投入买硬件做 P2。

---

## 十、原型采购清单（日本发货 / 省钱版，带链接）

前提：用户在**日本**。下面按"日本能发货"的渠道给，分预算档。链接是官方/正品
稳定页。币种用 USD + 日元约值（之前误用了人民币￥，已纠正）。

**关键省钱认知**：M5Stack Dial 是这里**最贵且最不划算**的——它把编码器/RFID/
RTC/外壳都捆进去了，而氛围屏根本用不到这些。最便宜的可行原型是一块**一体式
圆屏开发板**，一块板本身就是原型。

### 渠道（日本视角）

| 渠道 | 特点 | 适合 |
| --- | --- | --- |
| **Switch Science（スイッチサイエンス）** | 日本公司，国内发货次日达，无关税/无等待，单价略高 | 要快、怕清关 |
| **Amazon.co.jp** | Waveshare/LILYGO/M5Stack/树莓派都有，Prime 快 | 便利、国内 |
| **AliExpress（LILYGO/Waveshare 官方店）** | 最便宜，发日本约 1–3 周，运费低/免运，可能有少量消费税 | 省钱、不急 |
| **秋月電子通商 / 千石電商** | 离散件（舵机/WS2812/喇叭）最便宜，国内当天发 | Phase B 配件 |

### A. 现在就买（概念验证，按预算选一块主板即可）

**① 最省钱推荐 — Waveshare ESP32-S3-LCD-1.28（圆屏一体板）**
ESP32-S3 + 1.28″ 240×240 圆屏（GC9A01），一块板即原型，约 **$16（AliExpress
含运约 $23，约 ¥3,000–3,500 日元）**。
- 官方页：https://www.waveshare.com/esp32-s3-lcd-1.28.htm
- 触摸版：https://www.waveshare.com/esp32-s3-touch-lcd-1.28.htm
- 带 CNC 金属壳款（更像成品）：https://www.waveshare.com/esp32-s3-lcd-1.28-b.htm
- 买法：AliExpress 搜 **"Waveshare official store" → ESP32-S3-LCD-1.28**；
  或 Amazon.co.jp 搜 `Waveshare ESP32-S3 1.28 round`（更快、国内发货）

**①′ 极限便宜（愿意接线）** — AliExpress 搜 `ESP32 GC9A01 1.28 round display
board`，一体板约 **$8–12**。确认是"集成板"不是单块裸屏。最省，但要自己接线/确认引脚。

**② 大画布备选（以后做表情脸更爽）— Waveshare 圆屏大尺寸**
- 1.85″ 360×360：https://www.waveshare.com/esp32-s3-touch-lcd-1.85.htm
- 1.46″ 412×412，**板载喇叭+麦克风**（Phase B 声音直接省）：
  https://www.waveshare.com/esp32-s3-touch-lcd-1.46b.htm

**③ 只有"想要快+日本国内+开箱即成品外壳"才考虑 — M5Stack Dial v1.1**
最贵（Switch Science 约 ¥6,000+ 日元），氛围屏用不上它的旋钮/RFID。
- 日本发货：https://www.switch-science.com/products/10302
- 官方：https://shop.m5stack.com/products/m5stack-dial-v1-1

**预算备选（方屏，便宜但不像伴侣）— LILYGO T-Display-S3**
- 官方：https://lilygo.cc/en-us/products/t-display-s3
- LILYGO AliExpress 官方店（发日本、常免运）：https://lilygo.aliexpress.com/store/2090076

> 推荐组合（省钱版）：**只买 1 块 Waveshare ESP32-S3-LCD-1.28**（或带壳款）
> 跑通 Phase A，约 **$16–25（¥2,500–3,800 日元）**。USB-C 线手头一般就有；
> 常年通电用任意 5V/1A 充电头即可。两块板都想要再加一块 1.46″/1.85″。

### B. 之后再买（Phase B：表情/会动/声音，日本国内买最便宜）

- **舵机 SG90**（点头/转头，建议金属齿 MG90S）：秋月電子/千石/Switch Science
  约 ¥400–800/个。官方参考 https://www.waveshare.com/sg90-servo.htm
- **WS2812 RGB 灯环**（情绪光）：秋月電子/AliExpress，约 ¥300–900。
  Adafruit 正品参考 https://www.adafruit.com/product/1463
- **小喇叭 + I2S 功放 MAX98357A**：若选 Waveshare 1.46″ 已自带喇叭可跳过。
- 注意：舵机用独立 5V 电源轨，别和主控共用，避免堵转拉低电压重启。

### C. 可选 Linux 路线（只有想早做复杂动画/语音才考虑）

- Raspberry Pi Zero 2 W 官方页：https://www.raspberrypi.com/products/raspberry-pi-zero-2-w/
  （日本：Switch Science / KSY / Amazon.co.jp 均有）
- 另需小屏 + microSD。开发省心，但功耗/成本/量产一致性差，量产仍倾向 ESP32-S3。

### D. 到货后做什么（接回已完成的后端）

后端 `desk_snapshot` RPC 已就绪。固件按第四节状态机：配网 → 用配对码走
`register_helper`（`p_device_type='DeskCompanion'`）→ 轮询 `desk_snapshot` →
按返回的 `status` 枚举驱动屏幕/灯/蜂鸣。建议先用 P1 软件模拟器把渲染状态机
跑通，再烧到买回来的板子上——这样不急着花钱也能先验证概念。
