# 摩托导航卫士 · iOS 版（iPhone + CarPlay）

> 本工程是安卓版「摩托导航卫士」（v1.4，142 处合肥抓拍/限行点位）的 iOS 移植：
> SwiftUI 手机端 + CarPlay 车载端，含接近提醒、语音播报、路线规划、模拟测试、点位增删改与 JSON 导入导出。

## ⚠️ 重要前提（先读）

1. **本工程不能在 Windows/Linux 上直接产出 IPA**。iOS 应用签名依赖 macOS + Xcode + Apple 开发者账号，
   必须在 Mac 上完成构建。这不是本仓库缺失任何东西，而是苹果平台的硬性机制。
2. **免费 Apple ID 也可以装**：Xcode 里选个人免费 Team 直接 Run 到自己的 iPhone，但**每 7 天需重新签名安装一次**。
   想长期使用（不装 App Store）建议购买 Apple Developer 账号（¥688/年）。
3. **CarPlay 需要 Apple 单独审批**（见下）。审批通过前，App 在 iPhone 上完全正常，只是车机上不出现。

---

## 一、在 iPhone 上安装（最快路径）

1. 准备一台 **macOS 13+ 的 Mac**，安装 **Xcode 16**（App Store 免费下载）。
2. 打开终端，把工程解压到任意目录，然后：
   ```bash
   cd MotoNaviOS
   open MotoNav.xcodeproj
   ```
3. Xcode 打开后：
   - 左侧选 **MotoNav** target → **Signing & Capabilities**
   - 勾选 **Automatically manage signing**
   - **Team** 下拉选你自己的 Apple ID（没有就点 Add Account 登录；免费账号也能选）
   - 确认 Bundle Identifier 是 `com.motonav.app.ios`（可自行改名）
4. 用数据线连接 iPhone，点 Xcode 左上角 **▶ Run**。
5. iPhone 上首次打开需在 设置→隐私与安全性→定位服务 允许"使用期间"（如需息屏后台提醒，改选"始终"）。

> 若要生成可分享的 **IPA**：Xcode → Product → Archive → 在 Organizer 里选 **Distribute App → Development**（装到自己手机），
> 或 Ad Hoc/企业证书（装到多台手机）。免费账号只能 Development 且 7 天过期。

## 二、启用 CarPlay

CarPlay 不是普通的权限，而是**苹果控制的 Entitlement（能力），必须申请并获批**：

1. 需要**付费的 Apple Developer 账号**（免费账号没有 CarPlay 能力）。
2. 登录 [developer.apple.com](https://developer.apple.com) → **Certificates, Identifiers & Profiles** →
   找到本 App 的 Identifier → **Capabilities** → 勾选 **CarPlay**，在分类里选 **Maps / 导航类目** 提交申请。
3. 苹果审核通过后（导航类通常需说明用途、可能需要提供测试说明），该 Identifier 的 CarPlay 能力才会生效。
4. 工程里的 `Config/MotoNav.entitlements` 已写好 `com.apple.developer.carplay-maps` 键，
   获批后重新 Archive 签名安装，插上车机即出现图标。
5. **本工程的 CarPlay 代码按标准 API 编写**（`CPTemplateApplicationScene` + `CPMapTemplate` + 点位标注 +
   接近提醒弹 `CPAlertTemplate` + 车机语音播报 + 附近点位列表），获批后无需改代码。

## 三、功能对照（安卓 v1.4 → iOS）

| 功能 | iOS 实现 |
|---|---|
| 地图 + 142 点位着色标注 | MapKit（红=闯红灯 / 橙=限行禁摩 / 青=车道拍照） |
| 接近提醒（半径内语音+横幅） | 与安卓同引擎（90 秒冷却、离开重进）；AVSpeechSynthesizer 中文播报 + 本地通知 |
| 路线规划 | MapKit 官方路线（规划失败自动降级直线） |
| 模拟测试 | 内置环线模拟，可在室内验证提醒 |
| 点位增删改 / 启用开关 | 列表滑动删除、点按编辑、当前位置快捷添加 |
| JSON 导入 / 导出 | 与安卓版 `pois.json` 格式完全一致（142 点已内置，可互相导入） |
| CarPlay | 地图模板 + 附近点位标注 + 警示条 + 语音 + 点位列表 |
| 后台定位 | Info.plist 已配置 `UIBackgroundModes=location`，需在系统设置授予"始终" |

## 四、已知说明

- **坐标是估算值**：官方只公示路口名，坐标沿用安卓版估算，装车后请在现场用「加当前位置」或「手动坐标」校准。
  有高德/百度 Key 时可用官方 API 批量精确解析后重新导出 JSON 导入。
- **图标未放图**：`Assets.xcassets/AppIcon` 目前是占位，构建时会有 AppIcon 警告（不影响真机安装）。
  想上架或长期使用，替换成 1024×1024 的 PNG 即可。
- **CarPlay 分类说明**：本 App 是"提醒型导航"，申请导航类目时如实说明用途（摩托车骑行抓拍/限行提醒）。
  若只想先上车机体验，可改申请 Audio 类目并只做语音播报，但那样没有地图画面。
- 点位数据与安卓版同源（合肥市公安局 2025-2026 公示 + 霸都摩友社区清单），后续新增点可随时导出 JSON 双端同步。
