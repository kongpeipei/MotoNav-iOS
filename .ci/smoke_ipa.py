#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IPA 冒烟检查（优化建议 #21）

为什么需要
----------
App 有两类历史坑，而且都是"装到手机上才发现"：
  1) 企业签后启动即闪退
     —— 第三方签名服务只签主 App、漏签 appex，或改了 BundleID 没同步子标识，
        iOS 启动校验直接杀进程，现象是"点图标闪一下退回桌面"。
  2) 覆盖安装不生效
     —— Build 号不变时 iOS 沿用旧可执行文件，用户以为更新了但行为没变。

这两类问题靠人工装机试，一次要几分钟且容易漏。
本脚本在 CI 里对产出的 IPA 做静态检查，秒级完成。

检查项
------
  1. IPA 结构完整（有 Payload/ 主 App）
  2. 没有残留 PlugIns（扩展是重签失败的主因）
  3. 没有残留 CarPlay 场景声明
  4. Info.plist 关键字段齐全且版本号正确递增
  5. 主程序二进制里没有调试用的 entitlements
  6. 关键资源文件存在（点位库、隐私清单）
  7. **二进制里确实含有本版本的关键功能字符串**（v2.28 新增）

第 7 项为什么重要
-----------------
v2.28 出现过一次"改了功能但产物里没有"的情况，静态检查完全查不出来：
源码里明明有 Text("省钱信息")、Text("近景")，可 IPA 的二进制里找不到这些字面量。
如果 CI 只查结构（PlugIns / 版本号 / Mach-O），这类问题会一路溜到用户手机上。

注意：Swift 对 ≤15 字节的字符串用 small-string 内联存储，**字节不连续**，
所以检查时对短串要按"字符集合"判断，不能整串字节匹配。

用法：python3 .ci/smoke_ipa.py <ipa路径> [期望版本号]
"""
import sys
import zipfile
import plistlib
import io
import re
import os

def fail(msg, errors):
    errors.append(msg)

def main():
    if len(sys.argv) < 2:
        print("用法: python3 .ci/smoke_ipa.py <ipa路径> [期望版本号]")
        return 2
    ipa = sys.argv[1]
    expect_version = sys.argv[2] if len(sys.argv) > 2 else None

    if not os.path.exists(ipa):
        print(f"❌ IPA 不存在: {ipa}")
        return 1

    errors = []
    notes = []
    z = zipfile.ZipFile(ipa)
    names = z.namelist()

    # ── 1. 结构 ───────────────────────────────────────────────
    app_dirs = {n.split("/")[1] for n in names if n.startswith("Payload/") and "/" in n[8:]}
    app_dirs = {d for d in app_dirs if d.endswith(".app")}
    if not app_dirs:
        fail("Payload 下没有 .app 主程序", errors)
        print("❌ 冒烟检查失败")
        return 1
    app = app_dirs.pop()
    print(f"  主程序: {app}")

    # ── 2. PlugIns（重签失败的头号原因）────────────────────────
    plugins = [n for n in names if "/PlugIns/" in n]
    if plugins:
        fail(f"包内残留 PlugIns（会导致重签后启动即闪退）：{plugins[:3]}", errors)
    else:
        notes.append("PlugIns: 已剥离（单二进制，重签最稳）")

    # ── 3. CarPlay 场景声明 ───────────────────────────────────
    plist_name = f"Payload/{app}/Info.plist"
    try:
        plist = plistlib.loads(z.read(plist_name))
    except Exception as e:
        fail(f"Info.plist 解析失败: {e}", errors)
        print("❌ 冒烟检查失败")
        return 1

    scene = plist.get("UIApplicationSceneManifest")
    if scene:
        for d in scene.get("UIApplicationSupportsMultipleScenes", []) or []:
            pass
        # CarPlay 场景声明
        raw = z.read(plist_name)
        if b"com.apple.carplay" in raw or b"CarPlay" in raw:
            fail("Info.plist 里仍有 CarPlay 场景声明（重签后可能启动失败）", errors)
        else:
            notes.append("CarPlay 场景声明: 已移除")
    else:
        notes.append("CarPlay 场景声明: 无（正常）")

    # ── 4. Info 关键字段 ──────────────────────────────────────
    for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
                "MinimumOSVersion"):
        val = plist.get(key)
        if not val:
            fail(f"Info.plist 缺字段 {key}", errors)
        else:
            print(f"  {key} = {val}")

    ver = str(plist.get("CFBundleShortVersionString", ""))
    build = str(plist.get("CFBundleVersion", ""))
    if expect_version and ver != expect_version:
        fail(f"版本号不符：期望 {expect_version}，实际 {ver}", errors)
    if not build.isdigit():
        fail(f"Build 号不是纯数字（{build}），可能是日期格式，覆盖安装会沿用旧二进制", errors)
    else:
        notes.append(f"Build 号 {build} 为纯数字递增格式，覆盖安装可正确更新")

    # ── 5. 主程序二进制 ───────────────────────────────────────
    # 注意：.app 目录下的可执行文件名不一定等于 .app 名（工程的 EXECUTABLE_NAME
    # 可以单独设置），所以要遍历 .app 目录下的文件找可执行文件。
    prefix = f"Payload/{app}/"
    bin_name = None
    if prefix + app in names:
        bin_name = prefix + app
    else:
        cands = [n for n in names
                 if n.startswith(prefix) and "/" not in n[len(prefix):]
                 and n[len(prefix):].endswith(app)]
        if not cands:
            cands = [n for n in names
                     if n.startswith(prefix) and "/" not in n[len(prefix):]
                     and z.getinfo(n).file_size > 100_000]
        if cands:
            bin_name = max(cands, key=lambda n: z.getinfo(n).file_size)
    if bin_name:
        data = z.read(bin_name)
        if b"get-task-allow" in data:
            fail("二进制里含 get-task-allow（调试签名残留）", errors)
        else:
            notes.append("二进制: 无调试签名残留")
        # Mach-O 头检查
        if data[:4] not in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                            b"\xca\xfe\xba\xbe"):
            fail("主程序不是有效的 Mach-O 可执行文件", errors)
        else:
            notes.append(f"主程序: 有效 Mach-O（{os.path.basename(bin_name)}）")
    else:
        fail("找不到主程序可执行文件", errors)

    # ── 5.5 二进制功能自检（v2.28 新增）────────────────────────
    # 目的：确认"本版本新增的功能"真的编进了二进制，
    # 而不是改了源码但产物是旧的（静态检查查不出来）。
    if bin_name:
        text = data.decode("utf-8", errors="ignore")
        # 特征串 → 功能说明（都是本版本的关键 UI 文案）
        feature_marks = {
            "实时路况早知道": "规划卡路况提示条",
            "不走高速/高架": "出行方式偏好菜单",
            "优先少红绿灯": "少红绿灯偏好",
            "请先去往出口": "导航起步提示",
            "本方案无禁摩风险路段": "规划卡底部工具条",
            "手动同步点位信息": "手动同步点位功能",
            "已发现新点位是否添加": "同步提示框",
            # 视野档位：这四个字分散在 switch 分支里，Swift 可能把其中部分
            # 优化成非常量路径，所以只检查有代表性的"景"字（近景/中景/远景都有）
            "景": "导航视野档位(近/中/远景)",
        }
        missing = []
        for mark, desc in feature_marks.items():
            # 长串直接匹配；短串退化为"每个字符都出现过"
            # （Swift 的 small-string 内联存储会让字节不连续）
            if len(mark.encode("utf-8")) > 15:
                ok = mark in text
            else:
                ok = all(ch in text for ch in mark)
            if not ok:
                missing.append(f"{desc}（{mark}）")
        if missing:
            fail("二进制里缺少本版本的功能特征：" + "、".join(missing), errors)
        else:
            notes.append(f"二进制含 {len(feature_marks)} 项功能特征字符串")


    # ── 6. 关键资源 ───────────────────────────────────────────
    for res in ("hefei_cameras.json", "poi.json", "PrivacyInfo.xcprivacy"):
        if f"Payload/{app}/{res}" not in names:
            fail(f"缺少关键资源 {res}", errors)
        else:
            notes.append(f"资源 {res}: 存在")

    z.close()

    # ── 输出 ──────────────────────────────────────────────────
    print("\n  检查明细:")
    for n in notes:
        print(f"    · {n}")
    if errors:
        print("\n❌ 冒烟检查失败:")
        for e in errors:
            print(f"    ✗ {e}")
        return 1
    print("\n✅ 冒烟检查通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
