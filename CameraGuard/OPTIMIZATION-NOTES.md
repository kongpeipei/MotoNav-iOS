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

---

# 第七轮（v1.10 · CarPlay 音频类接入）

版本 1.9 → 1.10（构建号 10 → 11）。

## 背景与可行性结论

- CarPlay 车机屏幕**没有自由悬浮层 API**，跨 App/车机悬浮球受沙盒与模板约束，不可行；
- 仅**音频类**应用支持「连接 CarPlay 自动恢复播放 + 音频栏状态卡片」，导航类需 Apple 单独审批导航 entitlement（有真实导航能力要求，本 App 不满足，未采用）。

## 实施方案（音频类，无审核风险）

1. **静音占位流**：新增 `silence.wav`（0.6s 静音循环，音量 0），监听时持续播放，
   系统判定 App「正在播放」→ 连上 CarPlay 时**自动恢复 = 自动进入监听**，无需手点。
2. **CarPlay 连接检测**：监听 `AVAudioSession.routeChangeNotification`，输出端口含
   `carAudio` 即判定已连接；连接且已有定位授权时自动 `begin()` 开始监听（用户诉求）。
   断开时恢复普通状态文本。
3. **Now Playing 状态卡片**：`MPNowPlayingInfoCenter` 展示「电子眼卫士 · 监听中 / 已暂停 /
   前方 X 米 · 类型」，CarPlay 音频栏可看到；播报瞬间卡片同步当前提醒，离开预警恢复默认。
4. 播报语音沿用 `.playback + .spokenAudio` 会话，自动从车载音响输出（无需改播报链路）。
5. 首页状态栏新增 CarPlay 小标签（car.fill 绿标），连接时可见。
6. 分享按钮 URL 更新为 `camera-guard-v1.10` release 附件。

## 说明

- CarPlay 连接后如需在车机音频列表出现，用户最近播放过本 App 即可（静音流保证状态）。
- 实机验证点：连接车机后是否自动恢复播放并自动开始监听、播报是否从车载音响出声。

---

# 第八轮（v1.11 · 点位在线更新）

版本 1.10 → 1.11（构建号 11 → 12）。

## 云端点位库（同步最新摩托车抓拍点位）

- 数据源：仓库 main 分支 `CameraGuard/CameraGuard/poi.json`（raw.githubusercontent.com），
  零服务器成本：维护者更新仓库 → 全 App 一键同步。
- 点位管理新增「检查在线更新」：
  - 下载 → 逐条解析（坏条目跳过，与内置库同一 `parsePois`）→ 校验非空；
  - 持久化到 UserDefaults["remotePois"]，下次启动优先用云端库，无更新则回退 Bundle 内置库；
  - 更新后自动重建索引立即生效，并同步 CarPlay 卡片与灵动岛点位数。
- 与既有台账完全兼容：云端点位与内置点位共用同一批 id，删除/补丁/开关逻辑照常生效
  （`builtinPois` 改为基于 `basePois` = 云端库优先）。
- UI：内置点位计数显示改为云端库总数（`basePois.count`），更新状态行显示结果/失败原因。

---

# 第九轮（v1.12 · 修复点位管理进不去 + 移除悬浮球）

版本 1.11 → 1.12（构建号 12 → 13）。

## 1. 修复：点位管理点不进去 / 点进去看不到内容

根因：v1.9 的悬浮球覆盖层（`floatingBallOverlay`）使用全屏 `GeometryReader` 并
`allowsHitTesting(true)`，挂在根视图 body 上——推入导航子页面后该覆盖层仍叠在
导航栈最上层，吞掉了列表点击（点不进去），也遮挡子页面内容（看不到点位）。
v1.12 整体移除悬浮球覆盖层后，导航点击恢复正常。

## 2. 移除悬浮球及其全部设置开关

- 删除悬浮球 UI：绿色巡航球 / 红色预警球+米数 / 拖动手势 / 点击回主页。
- 高级设置第一项改为「提醒设置」：保留弹窗展示时长（1–10s，默认 1.2s）与
  灵动岛实时活动开关，**删除悬浮球总开关与允许拖动开关**。
- Engine 侧删除 `floatEnabled` / `floatDraggable` / `ballPosition` 及持久化；
  弹窗不再依赖悬浮球开关（`showBanner` 始终可用）。
- 预警提示链路保留：顶部弹窗（红色，按时长自动收起）+ 语音播报 + 灵动岛
  （后台/锁屏显示红色警告与距离）。

---

# 第十轮（v1.13 · 讯飞语音凭证加密内置 + 默认语音包）

版本 1.12 → 1.13（构建号 13 → 14）。

## 内容

1. **内置加密凭证**：新文件 `XfyunCredentials.swift`，使用 CryptoKit AES-GCM 把
   讯飞 AppID/APIKey/APISecret 加密后随包分发（密钥与密文分离，源码内无明文）；
   运行时解密注入语音引擎。固定密钥可防「静态明文提取」，本地内置凭证的通行做法。
2. **默认语音包**：首次启动自动使用内置发音人 `x4_lingxiaoxuan_en`（讯飞小璇·英文），
   语音包列表自动生成「讯飞小璇(英文)」；引擎默认切到讯飞（用户可从语音引擎页改回系统语音）。
3. **不落盘明文**：凭证值等于内置值时 `saveSettings` 不写入 UserDefaults（保持走内置解密）；
   仅当用户在语音引擎页显式修改后才持久化用户自己的值。
4. 语音引擎页提示更新：注明已内置默认凭证、留空即用内置、失败自动回退系统语音。

---

# 第十一轮（v1.14 · 修复设置页点不进去 + 放宽讯飞凭证预检）

版本 1.13 → 1.14（构建号 14 → 15）。

## 1. 修复：点位管理 / 语音引擎点不进去

根因：iOS 17 在 ScrollView 内使用 `NavigationLink(value:)` + `navigationDestination` 存在
点击失效的已知问题（点击无响应/页面不推入）。v1.14 改为**显式路径推入**：
两个入口改为 `Button { navPath.append(CameraGuardRoute.xxx) }`，由 NavigationStack(path:)
确定性驱动推入，不再依赖 NavigationLink 的命中测试/去重逻辑。

## 2. 讯飞凭证预检放宽

原预检要求 APIKey/APISecret 恰好 32 位，会把 24 位 hex 格式的有效 APIKey 误拦并回退
系统语音。v1.14 放宽为「AppID 8 位 + Key/Secret 各 ≥16 位」，真实有效性交给讯飞服务端判定，
App 只防空值。内置加密凭证逻辑不变（仍 AES-GCM 运行时解密、不落盘明文）。

## 3. 凭证有效性实测（本机直连讯飞 tts-api.xfyun.cn）

对当前内置凭证做了 WebSocket 直连验证：两种 APIKey 形式（原始 32 位 base64 样式、
base64 解码后的 24 位 hex）均返回 HTTP 401 `apikey not found`——该 APIKey 在讯飞服务端
不存在。App 在鉴权失败时回退系统语音并显示失败原因，属预期兜底行为；
待提供在讯飞控制台核验过的正确 AppID/APIKey/APISecret 后即可开箱即用讯飞合成。

---

# 第十二轮（v1.15 · 内置讯飞凭证修正为已验证组合）

版本 1.14 → 1.15（构建号 15 → 16）。

## 内容

上一轮内置的凭证（AppKey=OGE4… / AppSecret=9c32…）经讯飞服务端直连验证返回
`apikey not found`——用户复核对调后确认 Key 与 Secret 标反，正确组合为：
AppID=83344166 / AppKey=9c32a34d7d039eda93a5de05f3cc7c05 / AppSecret=OGE4OWFkZDNiNmFlMjY3ZjkwYjdjODhl / vcn=x4_lingxiaoxuan_en。

v1.15 重新生成 AES-GCM 密文并替换内置常量（仍加密存储、运行时解密、不落盘明文）。
新组合已在本机以同一协议（wss v2 + HMAC-SHA256）直连 `tts-api.xfyun.cn` 验证成功：
服务端返回成功、收到约 124KB PCM 音频（≈3.9s 16k 语音）。

---

# 第十三轮（v1.16 · 震动链路防崩溃加固，排查崩溃循环黄三角）

版本 1.15 → 1.16（构建号 16 → 17）。

## 用户报告现象

- 点位管理/语音引擎"点进去"显示白底黄色三角感叹号页
- 默认语音仍回退系统语音

## 崩溃日志分析（CameraGuard-2026-11-04-133459.ips）

- 崩溃线程：点「测试语音播报+震动」→ AlertEngine.testSpeak() → vibrate() →
  UIFeedbackGenerator(Statistics) 统计链在 stringWithFormat/CFString 扩容处
  **SIGSEGV 栈保护页击穿**；recursionInfoArray 显示栈上 AlertEngine.vibrate()
  递归省略计数 **31338 层**——无限递归栈溢出。
- bundleInfo 显示 CFBundleShortVersionString=1.0 / CFBundleVersion=1：
  **该崩溃包不是最新构建**（重签工具改写版本号或安装的是旧包）。
  App 崩溃后 iOS 26 崩溃循环检测 → 打开 App 即显示黄色三角警告页（系统页，非 App 内容），
  与截图吻合；"回退系统语音"亦为旧包行为（旧内置凭证 401 属 v1.14 之前状态）。

## v1.16 加固

- HapticsPlayer.play 全部请求改走**串行队列**（防重入/防高频叠加打爆调用栈）。
- 引擎不可用/播放失败的回退提示从 `UINotificationFeedbackGenerator` 改为
  `AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)`，避开 UIFeedbackGenerator
  统计链崩溃路径；新增 AudioToolbox import。
- 内置讯飞凭证（v1.15 已验证组合）不变。

---

# 第十四轮（v1.17 · 修复点位管理感叹号/语音引擎进不去：ForEach 重复 id 根因）

版本 1.16 → 1.17（构建号 17 → 18）。

## 用户反馈（装 v1.16 后）

- 语音包可用（内置讯飞凭证正常，说明 App 主体正常）
- 点位管理点进去显示黄色感叹号页
- 语音引擎点不进去

## 根因

Poi.id 是计算属性（类型+坐标6位小数）。检查仓库 poi.json（内置与云端同源 141 点）发现
**2 组同类型且坐标 6 位小数完全相同的真实点位**（桥上/桥下、两个方向的路口）→ id 冲突 →
PoiEditorView 的 ForEach(engine.builtinPois) 重复 id 断言失败 → iOS 26 SwiftUI 渲染错误
占位（黄色感叹号）。语音引擎同理：老用户手动建档 + v1.13 自动补内置包可能出现同 vcn 重复
语音包 → ForEach(engine.voicePacks) 断言。

## v1.17 修复

1. Poi.id 追加名称段（`类型-坐标6位#名称`）：同坐标不同名的真实点位各自独立；
   id 为计算属性，已持久化的旧数据（remotePois/userPois）自动获得新 id。
2. 台账双查兼容：builtinPois 的删除/补丁匹配同时查「新 id」与「稳定 id（类型+坐标6位）」，
   老用户已删除/已修改的点不复活、不丢失；新操作按精确 id 隔离，删桥上不影响桥下。
3. parsePois 按展示 id 去重（保首个），内置库与云端更新共用，杜绝未来数据再次冲突。
4. loadVoicePacks 按 vcn 去重，清理旧版本可能留下的重复语音包。

---

# 第十五轮（v1.18 · 新增运行日志按钮+自检，修复改名后点位开关/编辑失效）

版本 1.17 → 1.18（构建号 18 → 19）。

## 用户反馈

v1.17 后"还是不行"（具体现象待日志佐证）。诉求：右上角分享按钮左边加「软件运行日志」按钮用于检测运行问题。

## v1.18 新增

1. RingLog.swift：线程安全内存环形日志（800 条），关键路径埋点（启动/页面打开/云端更新/
   讯飞合成与回退/定位错误/测试播报/点位增删改）。
2. LogViewer.swift：日志查看页（复制/分享/清空）+「运行自检」——不触发 ForEach 渲染，
   直接复算内置/自定义点位重复 id、语音包重复 vcn、凭证完整性、定位权限，异常条目红色标出。
3. ContentView：右上角「运行日志」按钮（分享按钮左侧，doc.text.magnifyingglass 图标），
   路由新增 logViewer。

## 顺带修复（v1.17 引入）

Poi.id 追加名称段后，改过名的点 id 随之变化：toggleBuiltinPoi/updateBuiltinPoi 此前按新 id
匹配基库会找不到 → 改名后开关/编辑静默失效。v1.18 改为按稳定 id（类型+坐标6位）匹配基库，
兼容改名；同时清除旧键补丁防串。

# 第十五轮补充（v1.18 · 运行日志分享支持 .txt / .ips 文件）

- LogExporter.swift：导出 .txt（纯文本）或 .ips（模拟崩溃日志 JSON 结构：app_version/build_version/
  bundleID/os_version/device_model/异常项/事件日志，首行注释头），文件名贴近崩溃日志命名规则。
- LogViewer 分享按钮改为确认弹窗：日志文件(.txt) / 崩溃日志(.ips) 二选一，经系统分享面板发出。
- AlertEngine 补充 appBuild 静态属性（CFBundleVersion）。

---

# 第十六轮（v1.19 · 按用户要求回退 v1.10 形态：删除云端点位库与运行日志）

版本 1.18 → 1.19（构建号 19 → 20）。

## 用户指令

删除点位管理/语音引擎/运行日志按钮，去掉云端点位库功能，按 v1.10 中的点位管理与语音引擎
重做并添加到相同位置（高级设置入口）。

## 本轮改动

1. 删除全部运行日志：RingLog.swift / LogViewer.swift / LogExporter.swift 移除，
   ContentView 右上角恢复为仅分享按钮，route/navigationDestination 删 logViewer；
   AlertEngine 与各页面的日志埋点全部移除（pbxproj 同步注销）。
2. 删除云端点位库：remotePois / remoteUpdateStatus / checkRemotePointsUpdate /
   loadRemotePois / remotePointsURL 全部移除，点位管理页删「云端点位库」section，
   内置点位回退为 Bundle 内置库（bundledPois），显示「共 N 个」。
3. 点位管理按 v1.10 形态重做：操作（添加/导入/导出）+ 自定义点位 + 内置点位三段，
   入口仍在高级设置同位置；语音引擎按 v1.10 形态，仅保留 v1.13 内置凭证说明。
4. 保留防崩溃底层修复（避免旧问题复现）：
   - v1.12/1.14 导航入口仍用 Button+navPath（v1.10 的 NavigationLink 在 iOS 17
     ScrollView 内点击失效，会重新「点不进去」）；
   - v1.17 Poi.id 含名称段 + parsePois 去重（同坐标真实点位不冲突，防 ForEach 感叹号）；
   - v1.16 震动串行队列 + AudioServices 回退（防崩溃）；
   - v1.13/v1.15 内置加密讯飞凭证（默认语音包）。

---

# 第十七轮（v1.20 · 语音引擎展开式输入/震动三档/静止省电/一键恢复内置点位）

版本 1.19 → 1.20（构建号 20 → 21）。

## 用户指令

1. 语音引擎改为单入口选项：进入后选「系统语音/讯飞语音」；讯飞可输入 AppID/APIKey/APISecret/vcn
   自动添加语音包（可编辑名字），已有语音包左滑可删除；内置默认语音包（加密凭证）。
2. 点位管理：自定义点位置顶（v1.8 已实现，保持）；内置点位可修改/删除（v1.8 已实现，保持）；
   新增一键恢复全部内置点位。
3. 高级设置震动：持续时长 0~10 秒（0=关闭，v1.8 已有）；强度改「低/中/高」三档；
   控件滑动/切换有震动反馈。
4. ActivityKit 灵动岛：巡航绿色「电子眼卫士 · 正常巡航」，接近变红+横幅+锁屏距离/类型，
   离开恢复绿色（v1.9 实现即此行为，零改动确认）。
5. 分享按钮（v1.9 已有，保留）；CarPlay 方案 A（v1.10 已有：占位流/状态卡/连接检测，保留）。
6. 位置静止时省电。

## 本轮改动

1. AlertEngine：新增 restoreAllBuiltinPois()（清空删除台账+补丁，回出厂默认）。
2. 静止省电：process() 增加静止（<0.5m/s）12 秒评估节流，首次进入静止立即评估防漏播；
   tuneLocationAccuracy 静止档 NearestTenMeters + distanceFilter 60（降频不降精度，避免
   reduced accuracy 漂移破坏点位判定）；低速 30m / 高速 Best+10m 逻辑保留。
3. ContentView：震动强度 slider 改为「低/中/高」分段三档（0.35/0.65/1.0），切换即时震动反馈。
4. PoiEditorView：操作区新增「恢复全部内置点位」（带二次确认）。
5. VoiceEngineView：讯飞凭证从折叠 DisclosureGroup 改为直接展开输入区，文案明确
   「输入四项后自动生成语音包，可改名/左滑删除」。
6. 灵动岛/CarPlay/分享按钮确认已有实现满足需求，零改动。

---

# 第十七轮补丁（v1.21 · 点位管理感叹号崩溃根治）

版本 1.20 → 1.21（构建号 21 → 22）。用户装上 v1.20 后报「点位管理点不进去」，截图确认是
iOS 26 ForEach 重复 id 断言占位页（黄色感叹号）——v1.17 修复后首次实机复测暴露的漏网场景。

## 根因

`addUserPoi` / `importPois` 的去重使用**原始 double 精确比较**（lat == lat && lon == lon），
而 `Poi.id` 将坐标格式化为 **6 位小数**。两次添加/导入坐标微差（如 31.833001 vs 31.833000）
时，去重放行，但 id 归一化后完全相同 → 点位管理页 ForEach 重复 id → iOS 26 断言崩溃占位页。
v1.17 只修复了内置/云端解析（parsePois 按 id 去重），用户自定义点位这条路径从未覆盖。

## 修复（双层）

1. 源头：`addUserPoi` / `importPois` 去重改为按**6 位归一化坐标键**（类型+%.6f 坐标，
   与 Poi.id 前缀口径完全一致），微差坐标不再放行。
2. 渲染层兜底：AlertEngine 新增 `deduplicated(_:)`（按展示 id 折叠重复），
   PoiEditorView 的自定义/内置点位两处 ForEach 改用去重数组——历史遗留重复数据
   无论什么来源，进入点位管理页都只渲染一次，不再崩溃。
3. 补丁改名撞 id（如两个同坐标内置点被改成同名）同样被渲染去重兜底。

## 说明

- 首页/语音引擎/播报列表的 ForEach 逐一核查：枚举、announcements（唯一 id）、
  语音包（v1.17 已按 vcn 去重）均无重复风险。
- 若用户历史 userPois 有重复，本版渲染层会折叠重复行（少显示一条），不影响其余功能。

---

# 第十七轮补丁2（v1.22 · 首页两公里警告三角）

版本 1.21 → 1.22（构建号 22 → 23）。

## 用户指令

最近两公里有抓拍点时，首页距离提示卡的距离后方显示红色小三角形（内部白色感叹号）。

## 实现

- ContentView.nearestCard：距离文本改为 HStack，nearestDistance ≤ 2000 时在距离后
  追加红色小三角（15×13pt，TriangleShape + 白色粗体"!"），带无障碍标签「两公里内有抓拍点」；
  超过 2km 自动消失。进入预警半径（≤ effectiveWarn）时距离文字仍按原逻辑变红。
- TriangleShape 为新增 Shape（顶点在上），放在 ContentView 文件尾部。

---

# 第十七轮补丁3（v1.23 · 点位管理感叹号结构性根治）

版本 1.22 → 1.23（构建号 23 → 24）。用户确认语音引擎正常（语音包可用），感叹号仅点位管理。

## 关键判断

v1.16 报「点位管理感叹号」时诊断为 ForEach 重复 id（当时 Poi.id 无名称段，确有此问题，
v1.17 已修）。但 v1.21/v1.22 加上渲染层去重后用户实测**仍感叹号** → 说明 ForEach id 不是
（唯一）根因。真实根因高度指向 **iOS 26 上同一视图链叠加多个 .alert（3 个）+ 多个 .sheet（2 个）
+ 内层 NavigationStack 导致的 SwiftUI 渲染异常**（黄色感叹号占位页）。该结构自 v1.8 起一直存在，
用户从 v1.17 起从未实机验证过点位管理页，本次才暴露。

## 改动

1. PoiEditorView 结构性重构：
   - 去掉内层 NavigationStack，destination 直接 List + navigationTitle（dismiss 由外层提供）；
   - 3 个 .alert（2×item + 1×isPresented）合并为**单一 .alert(item: PoiConfirm)**，
     三种确认（删自定义/删内置/恢复内置）用枚举区分；
   - 2 个 .sheet（isPresented + item）合并为**单一 .sheet(item: PoiSheet)**（添加/编辑）。
2. VoiceEngineView 语音包列表改用 deduplicatedVoicePacks（按 vcn 去重兜底）。
3. AlertEngine 新增 deduplicatedVoicePacks。

---

# 第十八轮（v1.24 · 灵动岛生命周期管理）

版本 1.23 → 1.24（构建号 24 → 25）。用户反馈：App 从后台清除后灵动岛依然显示。

## 机制说明（向用户如实解释）

灵动岛 Live Activity 是 iOS 系统级实时活动，由系统渲染；App 进程被上滑清除后
灵动岛仍保留显示是系统设计（高德/百度等同），iOS 没有"App 被杀瞬间"的回调，
任何 App 都无法在杀掉的瞬间结束它。

## 实现（让行为完全可控）

1. scenePhase 驱动：App 退后台满 3 分钟未回前台 → endLiveActivity() 自动结束；
   回前台若监听中且开关开、活动已被自动结束 → 自动恢复灵动岛。
2. 冷启动清理：start() 里遍历 Activity.activities 把残留活动全部 immediate end，
   保证"重新打开 App 立即清理干净"。
3. 设置区新增说明文案：长按灵动岛可即时移除；后台 3 分钟自动结束；重开自动清理。

---

# 第十九轮（v1.25 · 灵动岛距离同步与预警全红）

版本 1.24 → 1.25（构建号 25 → 26）。用户需求：
1. 灵动岛右侧显示抓拍点距离（绿色），与 app 内提示卡同步；
2. 达到抓拍点提醒距离后，灵动岛所有图标文字变红。

## 改动

- App 端 makeActivityState：巡航态 distanceM 填充实时最近距离（原来填 0 导致右侧显示 "--"），
  detail 改为最近点位「类型 · 名称」与 app 内提示卡同步（无最近点时显示载入点位数量）。
- Widget 端：展开态 bottom 的 title/detail、锁屏卡 LiveActivityCard 的 title/detail
  在 warning 态全部变红（此前只有图标与右侧距离变红）。

## v1.25 补丁（用户澄清灵动岛生命周期）

用户澄清：需要的是"不清除后台 = App 持续后台运行 + 灵动岛一直显示；只有上滑清除才退出"。
- 删除 v1.24 的"后台 3 分钟超时自动结束"逻辑（违背用户预期）；
- 保留：回前台若活动被系统清理则自动补回；冷启动清理残留（上滑清除后重开即清）；
- 设置区文案同步更新。

---

# 第二十轮（v1.26 · 启动崩溃根治）

版本 1.25 → 1.26（构建号 26 → 27）。用户上传 .ips 崩溃日志：
iPhone OS 26.6.1，CameraGuard 1.25/build26，EXC_BREAKPOINT/SIGTRAP，主线程，
栈：start() → begin() → startLiveActivity() → makeActivityState() +1980。

## 根因（必现，不是偶发）

v1.25 把巡航态 distanceM 从固定 0 改为实时距离 `nearestDistance.isFinite ? Int(nearestDistance) : 0`，
但 nearestDistance 的初始/无点哨兵值是 `.greatestFiniteMagnitude`（1.8e308，isFinite 为 true）。
App 启动瞬间定位尚未更新距离时走巡航分支 → `Int(1.8e308)` 触发 Swift
"Double cannot be converted to Int" 运行时 trap（SIGTRAP）。v1.24 巡航 distanceM=0 所以不崩。

## 修复

- 新增 safeMeters(_:)：isFinite + 0...100000 钳制，异常值按 0；
- makeActivityState 三处 Int(nearestDistance) 全部改 safeMeters；
- 其余 Int() 转换核查：warnDistance 来自有限 Picker 选项，有界安全，无需改。

---

# 第二十一轮（v1.27 · 灵动岛右侧无"--" + 生命周期文案）

版本 1.26 → 1.27（构建号 27 → 28）。

## 改动

1. Widget 三处（展开态 trailing / compactTrailing / 锁屏卡右侧）不再显示 "--"：
   有有效距离（distanceM>0）显示数字，无距离时改显灰色 scope 图标（表示巡航定位中）。
2. 设置区灵动岛说明补充：系统数小时后自动清除；长按可立即移除。

## 关于"上滑清除 App 后同步清除灵动岛"

iOS 硬限制：上滑清除是系统 SIGKILL 终止进程，被杀瞬间没有任何 App 代码能执行
（无 applicationWillTerminate 回调），因此"杀瞬间结束灵动岛"无 API 可实现，
高德/百度等所有导航 App 行为一致。可用兜底：长按灵动岛立即移除（秒级）、
系统数小时后自动清除、重新打开 App 立即自动清理（已有 cleanupStaleLiveActivities）。

---

# 第二十二轮（v1.28 · 灵动岛中间抓拍类型图标）

版本 1.27 → 1.28（构建号 28 → 29）。用户确认图标方案（6 类），修改了
摩托车头盔（整车侧影）与自定义（定位图钉+感叹号），其余 4 类确认。

## 实现

- App 端 ContentState 新增 icon 字段（PoiType.rawValue，"" = 无最近点）；
  makeActivityState 按最近点位类型下发。
- Widget 端 ContentState 同步新增 icon；新增 poiTypeIconView（自绘 6 类：
  红绿灯/速度表/压线/摩托车/禁行圈/图钉，SwiftUI Shape + Path），
  展开态中间（标题左侧）与锁屏卡 title 前显示，巡航绿/预警红。
- 两个模块的 ActivityAttributes 字段保持完全一致（ActivityKit 匹配要求）。

---

# 第二十三轮（v1.29 · 速度门控休眠 + 头盔剪影 + 自定义文字）

版本 1.28 → 1.29（构建号 29 → 30）。v1.28 的图标集成（曾提交但未单独构建）
与 v1.29 三项改动一并交付：速度门控休眠、揭面盔剪影图标（用户最终指定）、
自定义类型显示"自定义"文字。

## 改动

1. 速度门控休眠（AlertEngine）：
   - 新增 `hibernating` 状态与阈值：>50km/h 唤醒监听、<10km/h 进入休眠（中间保持，
     避免阈值抖动）。
   - 休眠中：强制最低功耗定位（10 米精度 + 60 米过滤）；不预警不播报，
     仅刷新最近距离供灵动岛显示；灵动岛显示"电子眼卫士 · 休眠中"。
   - 唤醒瞬间立即恢复灵动岛巡航态。
2. 摩托车头盔图标：用户多轮确认，最终选定其上传的 500×500 纯黑白头盔剪影
   （"直接用这个"）。按剪影提取外轮廓（90 点）+ 面罩弧线（90 点），
   SwiftUI Shape 归一化绘制，巡航绿 / 预警红。
3. 自定义类型（CUSTOM）：灵动岛中间直接显示"自定义"三个字（7pt 粗体，
   与图标同色），不再用图钉图形；PinShape 删除。

## 说明

v1.28（build29）当时已提交但从未构建发布，其图标+距离功能随 v1.29 一并交付。

---

# 第二十四轮（v1.30 · 震动试震按档位强度 + 灵动岛右侧始终显示数字）

版本 1.29 → 1.30（构建号 30 → 31）。用户实机反馈两处问题：

## 改动

1. 震动强度三档切换无感知差异：hapticTick() 试震原本固定 0.35 强度，
   改为按当前档位强度（低 0.35 / 中 0.65 / 高 1.0）试震 0.15 秒，
   切换档位即可感受到强度变化。
2. 灵动岛右侧不再显示 scope 图标：三处（展开态 trailing / compactTrailing /
   锁屏卡右侧）无有效距离（distanceM<=0）时留空，与 app 内提示卡行为一致
   （有距离数字才显示）；有距离时始终显示提示卡同款数字（巡航绿/预警红）。

---

# 第二十五轮（v1.31 · 新增点位在提醒范围内立即提醒）

版本 1.30 → 1.31（构建号 31 → 32）。用户反馈：新增点位后，检测在提醒范围内应当立刻提醒。

## 改动

- evaluateNearest 新增 forceAnnounce 参数：点位操作（新增/启用/修改/恢复/导入）后
  调用 evaluateNearest(forceAnnounce: true)，若新点位已在提醒范围内，
  绕开语音节流（canSpeakNow 前台 8 秒/后台 30 秒）立即播报提醒。
- canSpeakNow 支持 force：强制播报时仍刷新 lastSpeak 节流时间戳，
  避免随后普通定位在 8 秒内被连报干扰。
- 覆盖操作：新增自定义点位、启用自定义/内置点位、修改点位（改名/改半径/改开关）、
  恢复被删内置点位、一键恢复全部内置、导入 JSON 点位。
