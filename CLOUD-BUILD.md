# 云端编译 IPA → 全能签安装（全程无 Mac 操作手册）

目标：不借用任何 Mac，用 GitHub 的免费虚拟机把工程编译成 IPA，再用全能签装到 iPhone。

---

## 第 1 步：准备 GitHub 账号

打开 https://github.com ，注册一个账号（免费，邮箱验证一下即可）。
> 没有账号的话注册 2 分钟；有账号直接登录。

## 第 2 步：把工程传到 GitHub

推荐下面 **方式 A**（最简单，图形化操作）；不方便装软件就用方式 B。

### 方式 A：GitHub Desktop（推荐）
1. 电脑下载安装 GitHub Desktop：https://desktop.github.com （Windows/Mac 都能用）
2. 打开后登录你的 GitHub 账号
3. 菜单 File → **New repository**：
   - Name 填 `MotoNav-iOS`（随便起）
   - 勾选 **Initialize this repository with a README**
   - 点 Create repository
4. 用文件管理器打开你电脑上刚解压的 `MotoNaviOS` 文件夹，**全选里面的全部内容**（含隐藏的 `.github` 文件夹）
   - Windows：按 `Ctrl+A` 全选即可（隐藏文件默认可见；如果看不到 `.github`，看 第 6 步后的说明）
   - Mac：`Cmd+Shift+.` 可显示隐藏文件
5. 把这些文件**拖进** GitHub Desktop 窗口中间的列表区
6. 左下角 Summary 随便填一句（如 `init`）→ 点 **Commit to main** → 再点 **Publish branch / Push origin** 按钮
   > 如果看不到 `.github` 文件夹：先在资源管理器/访达里把它复制进来，再重新拖一次；
   > 或者直接跳到方式 B 第 4 步的说明用网页补传。

### 方式 B：网页上传（不装任何软件）
1. GitHub 网页右上角 **+** → **New repository** → 填名字 `MotoNav-iOS` → 勾 README → **Create repository**
2. 进入仓库后点 **Add file → Upload files**
3. 先把 `MotoNaviOS` 里除 `.github` 外的所有文件和文件夹拖进去
   （网页上传会自动保留文件夹结构：直接拖整个文件夹即可）
4. 单独补 `.github/workflows/build-ipa.yml`：点 **Add file → Create new file**
   - 文件名栏直接输入 `.github/workflows/build-ipa.yml`
   - 粘贴 `MotoNaviOS/.github/workflows/build-ipa.yml` 的完整内容
   - 点 **Commit changes**
5. 同样方式把 `MotoNav.xcodeproj/xcshareddata/xcschemes/MotoNav.xcscheme` 也补上
   （路径输入 `MotoNav.xcodeproj/xcshareddata/xcschemes/MotoNav.xcscheme`，粘贴文件内容）

### 方式 C：git 命令行（熟悉命令的用）
```bash
cd MotoNaviOS
git init
git add .
git commit -m "init"
git branch -M main
git remote add origin https://github.com/你的用户名/MotoNav-iOS.git
git push -u origin main
```

## 第 3 步：运行云端编译

1. 浏览器打开仓库页面：`https://github.com/你的用户名/MotoNav-iOS`
2. 点上方 **Actions** 标签页
3. 左侧点 **Build IPA** → 右侧点 **Run workflow** → 绿色按钮 **Run workflow**
4. 等 3~8 分钟，那个任务跑完变绿 ✓

## 第 4 步：下载 IPA

1. 点开跑完的那条任务（绿色）
2. 页面底部 **Artifacts** 区域 → 点 **MotoNav-unsigned.ipa** 下载
3. 得到一个 `MotoNav-unsigned.ipa` 文件（约 20~30MB，未签名，专门给签名工具用的）

## 第 5 步：全能签安装

1. 手机/电脑把 `MotoNav-unsigned.ipa` 传给 iPhone（微信/网盘/爱思助手都行）
2. 全能签里点 **+ / 导入 IPA**，选中这个文件
3. 选证书：
   - 想最省事 → 用全能签里的**企业证书**（注意：来源不明的证书有被吊销风险，量力而行）
   - 自己的 Apple ID 自签 → 7 天有效，到期要重签
4. 点 **签名 / 安装** → 装好后 iPhone 桌面出现「摩托导航卫士」
5. 首次打开：允许定位；设置 → 隐私与安全性 → 定位服务 → 改成"始终"可后台提醒

## 常见问题

| 问题 | 处理 |
|---|---|
| Actions 里看不到 Build IPA | 仓库里 `.github/workflows/build-ipa.yml` 没传成功 → 用方式 B 第 4 步补传 |
| 编译报错 | 把报错截图发我，通常是小问题，几行代码的事 |
| 装完打不开/闪退 | 全能签重签一次；或换证书重装 |
| 提示"无法验证App" | 设置 → 通用 → VPN与设备管理 → 信任该证书 |
| 到期后打不开 | 个人自签 7 天有效期到了 → 全能签里重新签名安装 |

> ⚠️ CarPlay 提醒：全能签证书不包含 CarPlay 能力，这样装上后**车机上不会出现**这个 App，
> iPhone 端提醒功能完全正常。要上车机必须用获批的付费开发者证书直接签名安装。
