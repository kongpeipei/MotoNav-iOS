# CameraGuard（电子眼卫士）优化说明

本次围绕「安全修复 / Bug 修复 / 性能 / 代码重构 / UI 一致性」五个方向改造，不改变原有功能骨架与交互流程，共改动 7 个 Swift 源文件。

> 验证环境说明：当前为 Linux 云主机，无 Xcode/Swift 工具链，**无法执行 `xcodebuild` 真编译**；已完成括号平衡、符号引用、JSON 数据完整性等静态核查。**首次请在 Xcode 15+ 按文末清单编译回归一次**。

---

## 一、安全修复（最高优先级）

### 1. 移除源码中硬编码的讯飞密钥，默认改为离线系统语音
- 原 `AlertEngine.init` 内写死了 `xfAppID / xfAPIKey / xfAPISecret` 三个明文默认值，且默认引擎直接选中 `.iflytekPro`。
- 现改为：三项默认空串、`ttsProvider` 默认 `.system`（离线、零延迟、零流量）；凭证只由用户在「语音引擎 → 高级」里自行填写。
- 效果：源码不再携带任何可用密钥，新安装开箱即用系统语音。
- ⚠️ **重要**：旧密钥已经随公开仓库历史提交泄露，**请尽快到讯飞开放平台控制台作废并重新生成**；仅改工作区源码不会清除 Git 历史中的旧密钥，如需彻底清理历史需用 `git filter-repo` / BFG 处理并强制推送。

---

## 二、Bug 修复

### 2. 首页预警距离与引擎实际触发阈值不一致（界面误导）
- 原 `ContentView.effectiveWarn` 自行实现了一套速度系数，分支（≤5/≤10/≤15/≤22）与 `AlertEngine.adaptiveFactor`（≤10/≤15/≤22）不一致，且 UI 用 km/h 换算后阈值对不齐，导致首页显示的预警距离和真正播报触发的距离对不上。
- 修复：抽出共享 `AdaptiveWarn`（`AlertEngine.swift` 顶部 internal enum），提供 `factor(speedMetersPerSecond:)` 与 `effectiveDistance(base:speedMetersPerSecond:)`；引擎判定与首页显示都调用它，**只有一份阈值定义**，单位统一为 m/s。

### 3. 内置点位 JSON 单点解析失败会导致 141 条点位全部丢失
- 原 `try? JSONDecoder().decode([Poi].self, ...)`：数组里只要有一条类型/字段不合法，整个 decode 失败，`bundledPois` 为空，App 上车后无任何提醒。
- 修复：改为 `JSONSerialization` 取数组后**逐元素解码（compactMap）**，坏记录跳过、合法记录保留，不再一条坏数据拖垮全量。
- 已用脚本校验现有 `poi.json`：141 条记录，类型全部合法、坐标齐全。

### 4. 讯飞 WebSocket 异常断开时界面卡死在「合成中」
- 原 `didCloseWithError / didCompleteWithError` 只把错误存进 `errorMessage`，不触发收尾：若连接失败且没有音频，`onFinish` 永不回调，`xfyunTTS` 不释放，反馈文案停在「合成中」，且旧 session 残留。
- 修复：两个代理回调在主线程做收尾——已有音频则播放，无音频走 `failNoAudio()` 回退系统语音；`complete() / failNoAudio()` 中增加 `session.invalidateAndCancel()`；新增 `finalizing` 防重入标记，避免「正常播完」与「连接关闭」两个回调重复创建播放器导致一句播报播放两遍。

### 5. 导入点位的文件选择器回调可能不触发
- 原 `picker.delegate = ImportCoordinator(engine:)` 是临时对象：UIKit 不持有 delegate，协调器可能被提前释放，选完文件后无反应（导入静默失败）。
- 修复：用 `@State private var importer: ImportCoordinator?` 持有，生命周期跟随页面。

### 6. 系统语音连续播报互相截断
- 原 `speakSystem` 每次 `stopSpeaking(at: .word)` 硬打断上一句，路口密集时半句被切掉。
- 修复：默认不打断正在播放的句子（8 秒/30 秒节流已限制频率）；仅「测试语音」按钮通过 `force: true` 立即发声。

### 7. 讯飞发音人 vcn 去除首尾空白后仍用原值
- 原 `... .isEmpty ? "xiaoyan" : vcn` 分支返回的是**未修剪**的 `vcn`，带空格的自定义 vcn 会请求失败。修复为使用修剪后的值。

---

## 三、性能优化

### 8. `pois` 计算属性缓存
- 原 `pois` 每次被访问（状态栏计数、`rebuildIndex`、导出、UI）都对两个数组各做一次 `filter`；定位高频回调链路上反复执行。
- 修复：增加 `cachedPois / poiCacheValid`，数据未变时命中缓存；点位增删开关后 `invalidatePoiCache()` 失效重建。

### 9. 移除冗余的 UserDefaults 全局监听重建索引
- 原 `observeSettings()` 监听 `UserDefaults.didChangeNotification`，任何第三方写 defaults 都会触发一次全量 `rebuildIndex()`；而 `saveSettings()` 内部本来就会重建，属于重复劳动。
- 修复：删除该通知监听与 `deinit` 中的对应清理；设置变更统一经由 `saveSettings()` 重建索引。

### 10. 讯飞凭证输入防抖落盘
- 原 `VoiceEngineView` 对 3 个文本框逐字符 `onChange → saveSettings()`：每敲一个字符就写 UserDefaults 并 `rebuildIndex()`。
- 修复：文本类输入改为 0.6 秒防抖任务（`saveTask`），停止输入后再落盘；引擎切换、发音人选择仍即时保存。

### 11. 点位管理页减少重复过滤计算
- 原 `PoiEditorView.body` 对 `bundledPois.filter { $0.enabled }` 重复调用 3 次；提取为 `enabledBundled` 计算属性，结构更清晰、避免 body 多次重算。

---

## 四、代码质量 / 重构

| 项 | 改动 |
|---|---|
| 死代码删除 | 删除 `AddPoiView` 未使用的 `NumberFormatter`；删除 `AlertEngine.findNearest` 中计算后从未使用的 `lonKey` 变量，并修正粗筛注释 |
| 统一窗口获取 | `UIApplication.shared.windows.first`（已废弃）替换为 `connectedScenes → UIWindowScene → keyWindow`，抽取 `currentTopViewController()` 共用，导出/导入/报错弹窗三处统一 |
| 点位稳定标识 | `Poi.id` 由 `"\(lat)-\(lon)"`（浮点描述可能带尾差噪声）改为 `String(format: "%@-%.6f,%.6f", ...)`，同一坐标 id 稳定，避免 SwiftUI 列表不必要刷新/抖动 |
| 地址解析城市前缀 | 把写死在 `geocode()` 里的「合肥」提取为 `defaultCityHint` 常量，行为不变，便于按使用城市修改 |
| 注释清理 | 更新分桶粗筛、节流、不打断语音等位置的说明，使注释与实现一致 |

---

## 五、改动文件清单

```
CameraGuard/
├── CameraGuard/
│   ├── AlertEngine.swift      # 安全：去默认密钥/默认系统语音；AdaptiveWarn；pois 缓存；逐元素解码；不打断语音；删冗余监听
│   ├── ContentView.swift     # 复用 AdaptiveWarn，消除界面与引擎阈值漂移
│   ├── XfyunTTS.swift         # 断线收尾防悬挂；session 释放；finalizing 防重复播放；vcn trim 修复
│   ├── PoiEditorView.swift   # 持有导入协调器；窗口获取现代化；enabledBundled 缓存；共用顶层 helper
│   ├── VoiceEngineView.swift  # 凭证输入防抖保存
│   ├── AddPoiView.swift      # 删未用 formatter；城市前缀常量化
│   └── PoiModels.swift       # Poi.id 稳定化（6 位小数）
└── OPTIMIZATION-NOTES.md     # 本说明
```

---

## 六、建议在 Xcode 中的回归验证清单

1. **编译**：Xcode 15+ 打开 `CameraGuard/CameraGuard.xcodeproj`，Release 配置 `build`（对应 CI 的 `build-camera-guard.yml`），确认 0 error。
2. **默认语音**：全新安装后「语音引擎」默认显示「系统语音」，点「测试语音播报 + 震动」应立即出声并有震动。
3. **点位加载**：首页「载入 N 个点位」应显示约 141（= 内置 141 + 自定义），与修改前一致。
4. **阈值一致性**：低速/模拟不同速度下，首页大字下方「预警 X m」与实际触发播报距离应一致（同一 `AdaptiveWarn` 输出）。
5. **讯飞（仅填了有效凭证时）**：填错/断网时应自动回退系统语音，文案给出原因，且不卡在「合成中」；一次请求不重复播放。
6. **点位导入**：选 JSON 文件后成功合并；取消选择不报错。新增/删除/开关自定义点位后，首页计数与最近点实时刷新。
7. **后台定位**：切后台/锁屏后持续定位播报，`Info.plist` 权限描述未改动，授权流程同前。

## 七、未改动 / 刻意保留

- `poi.json` 数据、`Info.plist` 权限项、后台 `location/audio` 模式、工程 `pbxproj` 结构与版本号均未改动。
- 定位精度 `BestForNavigation` 与 `distanceFilter = 15m` 保留（骑行实时导航需要精度），未为省电降级以免延误预警。
- 未新增第三方依赖，未引入新文件到 Sources 编译阶段（无 pbxproj 变更），降低构建风险。

---

# 第二轮优化（v1.4 · 真实缺陷修复 + 功耗/体验）

本轮不做界面重做，只处理读代码能确认的缺陷与开销。版本号 1.3 → 1.4（`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` 1.3/4 → 1.4/5）。

## 1. Bug 修复

| # | 问题 | 根因 | 处理 |
|---|---|---|---|
| 1 | 「最近播报」左滑删除完全无效 | `swipeActions` 只对 `List` 行生效，页面在 `ScrollView` 里 | 每行改为显式 × 删除按钮，点击即删，功能真正可用 |
| 2 | 从「文件」/iCloud 导入 JSON 选完没反应 | 文档选择器 URL 是安全作用域资源，未调用 `startAccessingSecurityScopedResource()`，`Data(contentsOf:)` 直接失败 | 读取前申请访问、`defer` 释放；失败/成功都弹明确结果 |
| 3 | 一条坏记录导致整批导入失败 | 导入用 `JSONDecoder().decode([Poi].self)`，数组任一元素不合法就整体抛错 | 改 `JSONSerialization` 逐条解析，坐标范围校验 + 去重，坏数据只跳过并计数 |
| 4 | 导入报错弹窗偶发不出现 | 选择器未收起时从根控制器 present 会静默失败；且只取 rootVC，sheet 叠层时弹不出 | 沿 `presentedViewController` 链取最上层控制器；弹窗延后 0.35s 到收起动画结束 |
| 5 | 讯飞连播时两句叠播/连接泄漏 | 每次播报新建 `XfyunTTS`，不停止上一段进行中的请求 | 新建前 `stop()` 旧实例并置空 |
| 6 | 播报后首页一直显示「即将播报」 | `announced` 只用于内部节流，未暴露给界面 | `announced` 改 `@Published`，播报后显示「✓ 已播报，请减速通过」 |
| 7 | 申请了通知权限却从未发过通知 | 后台只靠语音，锁屏/静音时容易漏提醒 | 后台触发播报时同步发一条本地通知（前台不发），权限终于有实际用途 |
| 8 | 改播报距离/语音设置也重建全量点位索引 | `saveSettings()` 内无条件 `rebuildIndex()` | 增加 `rebuildIndex:` 参数，只有点位增删/开关/导入才重建 |

## 2. 功耗优化

- 原实现始终 `kCLLocationAccuracyBestForNavigation` + `distanceFilter = 15`，等红灯、停车时也在满负荷定位。
- 现按车速切换：≥ 5 m/s 用 `Best` + 10 m 过滤；低速/静止降到 `NearestTenMeters` + 30 m 过滤；进入 3 m/s / 退出 5 m/s 双阈值做滞回，避免阈值抖动反复切换。
- 预警逻辑不变：低速时自适应系数本来就是 1.0×（预警距离短），10 米精度足够。

## 3. 兼容性 / 稳定性

- `saveSettings()` 签名变化只影响本工程内部 6 处调用，已全部同步。
- 未改 `poi.json`、`Info.plist` 权限项与后台模式、未新增源文件、无 `pbxproj` 结构改动（只改版本号）。

## 4. 验证方式

- 推送后由 `.github/workflows/build-camera-guard.yml`（macos-15 + Release，未签名）真实编译，以 CI 结果为准；本机为 Linux，无法本地 `xcodebuild`。
- 静态自查：全部 Swift 文件花括号/圆括号平衡；`swipeActions` 已无残留；`importPois` / `saveSettings` 调用点全部对齐新签名。

---

# 第三轮（v1.5 · 语音包改为自定义管理）

按使用反馈调整语音引擎逻辑，版本 1.4 → 1.5（构建号 5 → 6）。

## 改动

1. **删除全部内置语音包预设**：移除 `VoicePreset` / `VoicePresets`（小燕、小峰、小宇…叶子四川话共 8 个）以及对应的选择列表；源码不再预设任何发音人。
2. **输入 vcn 自动建包**：在「高级」里填写 `发音人 vcn`，停止输入 0.6 秒后自动生成一条语音包（名称默认等于 vcn），并保持选中；重复 vcn 不会重复添加。
3. **名称可编辑**：语音包列表里直接改名称，vcn 不变；名称编辑做 0.6 秒防抖落盘。
4. **左滑删除**：语音包列表在 `Form`（List）里，`swipeActions` 正常生效；删掉当前选中项时自动切换到剩余第一个，全部删完则清空 vcn。
5. **持久化**：语音包存 `UserDefaults` 的 `voicePacks`；老用户升级后若已有 `xfVcn`，首次启动自动补一条同名语音包，不会丢配置。

## 验证

- 编译由 CI（build-camera-guard.yml，macos-15 / Release）确认。
- 交互验证清单：① 高级里输入 `xiaoyan` → 列表出现一条 `xiaoyan` 语音包并被选中；② 改名后杀进程重开仍保留；③ 左滑删除 → 列表消失；④ 删除当前项后选中项自动切换。

---

# 第四轮（v1.6 · 可配置震动 + 始终定位引导）

版本 1.5 → 1.6（构建号 6 → 7）。

## 1. 震动提醒（CoreHaptics）

- 高级设置新增两项：
  - **震动时长**：0 秒 = 关闭，最长 60 秒，0.5 秒步进；
  - **震动强度**：0~100%，10% 步进。
- 新增 `HapticsPlayer`：用 `CHHapticEngine` 的 continuous 事件实现「可控时长 + 可控强度」的一次连续触感；每次播放前停掉上一段，避免叠震。
- 设备不支持 CoreHaptics 或引擎启动失败时，自动回退 `UINotificationFeedbackGenerator` 警告触感，提醒不会完全丢失。
- 生效范围：**测试按钮**（`testSpeak`）与**抓拍点提醒**（`evaluateNearest` 播报时）共用同一个 `vibrate()`，都按设置执行；时长为 0 时两者都不震。
- 设置持久化到 `hapticDuration` / `hapticIntensity`。

## 2. 启动询问「始终」定位

- `AlertEngine.begin()` 与授权回调中，若当前仅为「使用期间」授权，置 `showAlwaysPrompt = true`；首页弹出引导：
  - 「现在允许」→ `requestAlwaysAuthorization()`；
  - 「去系统设置」→ 跳转本 App 设置页；
  - 「稍后」→ 关闭。
- 已授权「始终」时不再打扰。

## 3. 验证

- CI 编译（build-camera-guard.yml，Release）。
- 真机交互清单：① 时长拖到 0 → 测试按钮只有语音无震动；② 时长 3 秒 + 强度 100% → 测试与接近抓拍点时均为持续 3 秒强震；③ 强度 30% 明显变弱；④ 首次仅授权「使用期间」→ 启动弹「开启始终定位」。

---

# 第四轮（v1.7 · 震动开关 + CI 修正）

版本 1.6 → 1.7（构建号 7 → 8）。

## 1. 震动改为显式开关（更符合“开关”语义）

- 高级设置里新增 **震动提醒 Toggle**：关闭即 `hapticDuration = 0`；重新打开恢复上次时长（`hapticLastDuration` 持久化，默认 1.0 秒），不会每次从 1 秒重来。
- 开关打开后才显示 **持续时间滑杆 0.5~60 秒** 与 **强度滑杆 0~100%**，避免滑杆拖到 0 时开关同时跳变导致状态错乱。
- 时长落盘统一走 `setHapticEnabled` / `updateHapticDuration`，删掉重复的 `onChange` 落盘。

## 2. 震动生效范围（不变，确认一致）

- 测试按钮 `testSpeak()` → `vibrate()` → `HapticsPlayer.play(duration:intensity:)`。
- 真实抓拍点提醒 `evaluateNearest()` → 同样调用 `vibrate()`，与设置同一份参数。
- Core Haptics 连续触感支持自定义时长/强度；设备不支持或引擎启动失败回退系统警告触感。

## 3. 启动询问「始终定位」

- 启动时若授权仅为「使用期间」，会请求升级并弹出引导弹窗：**现在允许 / 去系统设置 / 稍后**；仅「使用期间」时后台锁屏播报不可靠，因此主动提示。

## 4. CI 修正（关键）

- `build-camera-guard.yml` 的 `runs-on: macos-13` 改回 **macos-15**：GitHub 已于 2025-12-04 正式退役 macOS 13 镜像，指向 macos-13 的任务只会一直排队直至被取消，永远出不了包。

## 5. 待验证

- 本地无 Xcode/Swift 工具链，未做本地编译；已做括号平衡、符号引用、调用点一致性静态核查。
- GitHub 托管 macOS runner 当前出现排队被取消（运行器未分配），构建结论以 CI 实际跑通为准。

## 编译修复（v1.7 · build 8 内）

- **根因**：v1.5 把 `voicePacks` 的恢复逻辑放在 `super.init()` 之前，Swift 不允许在 super.init 前访问 `@Published` 属性（`'self' used in property access 'voicePacks' before 'super.init' call`）。该错误自 v1.5 起一直存在，但因 macOS runner 短缺从未真正编译暴露。
- **修复**：抽出 `loadVoicePacks()` 私有方法，在 `super.init()` 之后调用；读取/补包逻辑不变。
- **验证**：2026-11-05 08:07 UTC+8 首次拿到真实编译日志，错误仅此一条；修复后重新派发 CI 出包。

---

# 第五轮（v1.8 · 点位管理排序/内置可编辑 + 震动时长 0-10 秒）

版本 1.7 → 1.8（构建号 8 → 9）。

## 1. 点位管理

- **自定义点位移到内置点位上方**，方便先看/改自己加的点。
- **内置点位支持修改与删除**：
  - 删除走持久化台账（`deletedBuiltinIds`），坐标/类型固定，App 升级可恢复默认；
  - 修改（名称/预警半径/启用开关）走补丁表（`builtinPatches`），坐标与类型锁定不可改；
  - 列表行新增铅笔编辑按钮；删除二次确认。
- 内置点位生效列表 `builtinPois` = 内置 − 已删除 + 补丁；首页 `pois` 合并逻辑同步切换到生效列表。
- 自定义点位也顺手支持编辑（同一编辑弹窗）。

## 2. 震动时长

- 滑杆范围由 0~60 秒改为 **0~10 秒、步进 1 秒**（0 仍为关闭）。
- **滑到整秒时触发一次短促震动提示**（`hapticTick()`，0.12s / 35% 强度），松手才落盘最终时长。

---

# 第六轮（v1.9 · 悬浮球 + 顶部弹窗 + 灵动岛 + 分享安装包）

版本 1.8 → 1.9（构建号 9 → 10）。

## 1. 悬浮球（App 内覆盖层）

- 常态绿色小圆球（显示 `--`），覆盖在 App 任意页面（含点位管理/语音引擎等子页面）之上。
- **接近抓拍点**：先顶部弹红色横幅（文案「前方 X 米 · 类型」+ 图标），同时语音播报 + 震动 + 本地通知照旧；
  弹窗按设置时长自动收起后，悬浮球变**红色**并在球内显示距点位米数。
- **离开抓拍点**（超过预警半径）自动恢复绿色。
- 悬浮球**可拖动**，位置以归一化坐标持久化（换机型不跑偏）；拖动结束自动落盘。
- **点击悬浮球**：一键回到主界面（清空导航栈路径）。
- iOS 无原生跨 App 悬浮球 API（沙盒限制），此为 App 内悬浮球方案；后台/锁屏由灵动岛承接。

## 2. 高级设置第一项：悬浮球设置

- 总开关（关掉后悬浮球/弹窗一并隐藏，并结束灵动岛）；
- 允许拖动悬浮球（开关）；
- 弹窗展示时长：**1 ~ 10 秒，默认 1.2s**（滑杆步进 0.1s）；
- 灵动岛实时活动开关（后台/锁屏显示）。

## 3. 灵动岛 / Live Activity（ActivityKit）

- 新增 Widget 扩展 target `CameraGuardWidget`（bundle `com.motonav.app.eye.widget`），仅含
  `ActivityConfiguration`，无桌面小组件；App Info.plist 增加 `NSSupportsLiveActivities`。
- 监听开始时启动实时活动，暂停/退出时结束；进入/离开预警、距离刷新时同步更新：
  - 巡航态：绿色 scope 图标 + 「电子眼卫士 · 正常巡航」；
  - 预警态：红色三角 + 球内米数 + 「前方 X 米 · 类型」。
- 灵动岛（紧凑/展开/最小）与锁屏卡片同套状态。
- ⚠️ 未签名 IPA + 全能签环境下灵动岛是否正常展示需实机验证；代码按标准 ActivityKit 实现，
  不支持时优雅降级（不影响悬浮球/语音/震动主链路）。

## 4. 右上角分享按钮

- 导航栏右上角新增**苹果同款分享图标**（square.and.arrow.up）。
- 点击弹出系统分享面板（UIActivityViewController），将当前版本 IPA 的公开下载地址
  （GitHub Release 附件）+ 版本说明分享到微信/QQ/其他渠道。
- 分享文案带版本号（读取 CFBundleShortVersionString 动态取）与「未签名需全能签重签」提示。
- 每轮发布对应更新 `ContentView.ipaShareURL` 常量中的 release tag。
