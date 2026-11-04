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
