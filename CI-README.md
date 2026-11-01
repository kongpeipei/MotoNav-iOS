# 骑士地图 v1.92 · 云编译交付说明

> 基于 kongpeipei/MotoNav-iOS 的 **v1.91（933e13f）** 修改，以下是我改动过的内容与使用方法。

---

## 一、改了什么

### A. 打包环节（原 v1.91 的 IPA 只有 772 KB，结构不可靠）

| 项 | 原仓库工作流 | 本版 |
|---|---|---|
| 出包方式 | 裸 `xcodebuild build` + 手工 `cp` Widget 进 PlugIns | `archive` → 导出（失败自动降级手工装包） |
| Widget | 单独 target 编译后拷贝 | scheme 依赖自动进 `PlugIns/`，版本号自动对齐 |
| 体积 | 原样 | 剥离 `.dSYM`/`.swiftmodule`/`.swiftdoc`，Swift 库只留 arm64 |
| 排错 | 单步跑到底，日志被吞 | 15 步分段，失败自动上传 `compile.log`/`archive.log` |
| 产物名 | `MotoNav-unsigned.ipa` | `MotoNav-unsigned-v1.92-b<时间戳>.ipa` + `.sha256` |

### B. 工程层两个签名/运行隐患（构建期自动修补）

`.ci/sync_extensions.py` 在编译前自动处理（幂等，重复执行无副作用）：

1. **Live Activity 起不来**：`ActivityModels.swift` 的 `ContentState` 没有 `public init`，而 `ActivityAttributes` 必须有；主 App 与 Widget 是两个模块，跨模块拿不到内部 init，灵动岛/锁屏卡片可能直接失效。→ 自动补 init。
2. **CarPlay 导致秒退**：`Info.plist` 声明的 CarPlay 场景指向 `CarPlaySceneDelegate`（`import CarPlay`）。全能签证书不含 `carplay-maps` 能力时，系统加载该场景会崩。→ 自动把 delegate 置空（手机端功能完全不变）。

### C. 省电模块逻辑缺陷（v1.90 引入，v1.92 修复）

| # | 问题 | 修复 |
|---|---|---|
| 1 | 退出省电时把 `distanceFilter` 写成 `kCLDistanceFilterNone`（每次移动都回调），**反而比省电前更耗电** | 记录进入省电前的原值，退出时还原 |
| 2 | 导航中也降频 50 米，转向/电子眼提醒会推迟几十米才报 | 导航中一律不降频，只在非导航态降频 |
| 3 | 全屏盖 25% 黑罩"省电"，但瓦片仍全量渲染；且导航中也盖，户外看不清路口 | 黑罩仅在非导航态显示 |
| 4 | 每下载一张瓦片就全目录枚举+排序一次，滚地图会触发数百次 | 每 50 张清理一次，App 进后台补清一次 |
| 5 | `batteryStateDidChange` 通知在 App 挂起时收不到，后台耗电场景恰恰判不到 | 在定位回调里每 ≥60 秒复查一次电量 |
| 6 | 到达用 `AudioServicesPlaySystemSound` 固定强度"嗡"一声，头盔+风噪下几乎无感 | 改为三连 `UINotificationFeedbackGenerator(.success)` |

### D. 密钥泄露（重要）

原本硬编码在 `AppModel.swift` 且**已随公开仓库泄露**：

- 高德 Web 服务 Key（原 `AppModel.swift` 中 `builtinAmapKey`）
- 讯飞 AppId / ApiKey / ApiSecret（原 `xfAppIdDefault` 等三项）

完整明文我就不在文档里复述了，避免二次扩散。

任何人可取用刷配额，**配额耗尽后地图搜索联想、路线规划、语音播报会全部失效**。

处理：明文从源码移除，改为构建期注入（新增 `MotoNav/Secrets.swift`）。

> ⚠️ **请先到高德开放平台和讯飞开放平台控制台把这两个 Key 重新生成**（旧的已经公开，无法收回），拿到新 Key 后按下面第三节配置。

---

## 二、怎么用（3 步）

### 1. 推到你的仓库

```bash
cd MotoNav-iOS
git init && git add -A && git commit -m "v1.92: 打包流程 + 省电修复 + 密钥外置"
git branch -M main
git remote add origin https://github.com/<你的用户名>/MotoNav-iOS.git
git push -u origin main --force   # 覆盖式推送，确认仓库是你的再用
```

网页上传时注意 `.github`、`.ci` 是**隐藏目录**，容易漏传。传完在仓库页面确认这两个目录存在。

### 2. 配置密钥（可选，但建议）

仓库 → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**，添加：

| Name | 内容 | 不配会怎样 |
|---|---|---|
| `AMAP_KEY` | 高德 Web 服务 Key | 在线搜索联想/路线规划不可用，其余正常 |
| `XF_APP_ID` | 讯飞 AppID | 语音自动降级系统 TTS |
| `XF_API_KEY` | 讯飞 APIKey | 同上 |
| `XF_API_SECRET` | 讯飞 APISecret | 同上 |

不配置也能编译通过，只是功能降级。也可以在手机 App 内「我的 → 高德 Key」直接填。

### 3. 跑构建

**Actions** → **Build IPA** → **Run workflow**：

| 输入项 | 默认 | 何时改 |
|---|---|---|
| `fix_widget_point` | `widgetkit` | 灵动岛/锁屏卡片不显示时改 `activitykit-extension` 重跑 |
| `optimize_size` | `true` | 想对比体积时关掉 |

约 6–12 分钟 → Artifacts 下载 `MotoNav-unsigned`。

---

## 三、装机后排查

| 现象 | 处理 |
|---|---|
| 打开秒退 | 先看证书是否匹配（Bundle ID `com.motonav.app.ios`）；再换 `fix_widget_point` 重跑 |
| 灵动岛/锁屏无卡片 | 换 `activitykit-extension` 重跑 |
| 车机不显示图标 | 预期行为——企业/个人自签证书无 CarPlay 能力，iPhone 端功能完整 |
| 地图是空白/灰屏 | 高德 Key 没配或配额耗尽，去「我的」页填一个自己的 Key |
| 语音是系统音色 | 讯飞三值没配，属预期降级 |

Widget 的 Bundle ID 是 `com.motonav.app.ios.Widget`，全能签若要求填扩展 ID 就填这个。

---

## 四、建议的验证顺序

1. 用本版工作流出一个包 → 先确认**能装、不闪退**（这是 772 KB 那版最可能出问题的地方）
2. 确认不闪退后，再看电量掉到 20% 以下时定位频率是否真的降下来
3. 最后按第三节配密钥，恢复地图联想与四川话语音

---

## 五、关于我无法代做的事

- 我没有 macOS，无法在本地真编译验证 Swift 代码，改动只做了静态校验（符号引用、括号平衡、API 可用性）。CI 会给出最终结论。
- Actions 产物与日志需要仓库管理员权限才能下载，我这边拿不到，需要你在浏览器里下载。
- 如果你给我一个有 `repo` + `workflow` 权限的 GitHub token，我可以直接推送代码、触发构建、读取日志并帮你定位编译错误。
