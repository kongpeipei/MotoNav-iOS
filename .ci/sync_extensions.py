#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CI 构建前处理：为「无签名 IPA（供全能签/AltStore 重签）」做工程兜底修补。

只做三件事，全部幂等（重复执行结果一致）：
  1. 主 App 的 Live Activity 模型补齐 `public init`：
     ActivityAttributes 要求 ContentState 有公开初始化器，而 extension 与之分处两个模块，
     内部 init 在打包时可能拿不到，导致运行期 Live Activity 起不来。补 init 不改变行为。
  2. 主 App 的 CarPlay Declared Scene 指向 CarPlaySceneDelegate，该文件 import CarPlay。
     重签证书若不含 carplay-maps 能力，系统加载场景时 target 未声明该能力会崩。
     处理：把声明改名并置空 delegate class（仅影响 CarPlay 场景，手机端不受影响）。
  3. MotoNavWidget 目前只含 WidgetKit 扩展代码（Live Activity UI），
     却按 widgetkit-extension 打包；若装机后出现启动失败，可把 build.yml 里的
     FIX_WIDGET_POINT 设为 activitykit-extension。此脚本按该键切换。

用法: python3 sync_extensions.py <仓库根目录>
"""
import os
import plistlib
import re
import sys


def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def patch_activity_models(root):
    p = os.path.join(root, "MotoNav", "ActivityModels.swift")
    if not os.path.exists(p):
        print("[skip] ActivityModels.swift 不存在")
        return
    src = read(p)
    if "public init(poiName:" in src:
        print("[ok] ActivityModels: ContentState init 已存在")
    else:
        pat = re.compile(
            r"(public struct ContentState:\s*Codable,\s*Hashable\s*\{)(.*?)(\n\s*\})",
            re.S,
        )
        m = pat.search(src)
        if not m:
            print("[warn] ActivityModels: 未匹配到 ContentState，跳过")
        else:
            body = m.group(2).rstrip()
            init = (
                body
                + "\n\n        public init(poiName: String, poiType: String, distanceM: Int) {"
                "\n            self.poiName = poiName"
                "\n            self.poiType = poiType"
                "\n            self.distanceM = distanceM"
                "\n        }"
            )
            src = src[: m.start(2)] + init + src[m.end(2):]
            write(p, src)
            print("[fix] ActivityModels: 已为 ContentState 补 public init")

    if "public init(destName:" in src:
        print("[ok] ActivityModels: Attributes init 已存在")
    else:
        pat2 = re.compile(
            r"(struct MotoNavAttributes:\s*ActivityAttributes\s*\{)(.*?)(\n\})", re.S
        )
        m2 = pat2.search(src)
        if not m2:
            print("[warn] ActivityModels: 未匹配到 MotoNavAttributes，跳过")
            return
        body = m2.group(2).rstrip()
        init = body + "\n\n    public init(destName: String) {\n        self.destName = destName\n    }"
        src = src[: m2.start(2)] + init + src[m2.end(2):]
        write(p, src)
        print("[fix] ActivityModels: 已为 MotoNavAttributes 补 public init")


def patch_carplay_scene(root):
    p = os.path.join(root, "Config", "Info.plist")
    if not os.path.exists(p):
        print("[skip] Config/Info.plist 不存在")
        return
    with open(p, "rb") as f:
        data = plistlib.load(f)

    sceneman = data.get("UIApplicationSceneManifest", {})
    configs = sceneman.get("UISceneConfigurations", {})
    role = "CPTemplateApplicationSceneSessionRoleApplication"
    arr = configs.get(role)
    if not arr:
        print("[ok] Info.plist: 无 CarPlay 场景声明，无需处理")
        return

    changed = False
    for item in arr:
        if item.get("UISceneDelegateClassName"):
            item["UISceneDelegateClassName"] = ""
            changed = True
        if not item.get("UISceneConfigurationName", "").lower().startswith("carplay"):
            item["UISceneConfigurationName"] = "CarPlay"
            changed = True

    if changed:
        with open(p, "wb") as f:
            plistlib.dump(data, f, sort_keys=False)
        print("[fix] Info.plist: CarPlay 场景 delegate 已置空（避免重签无能力时崩溃）")
    else:
        print("[ok] Info.plist: CarPlay 场景已是安全状态")


def patch_widget_point(root):
    mode = os.environ.get("FIX_WIDGET_POINT", "widgetkit").strip()
    if mode == "widgetkit":
        print("[ok] Widget: 保持 com.apple.widgetkit-extension")
        return
    p = os.path.join(root, "WidgetConfig", "Info.plist")
    if not os.path.exists(p):
        print("[skip] WidgetConfig/Info.plist 不存在")
        return
    with open(p, "rb") as f:
        data = plistlib.load(f)
    ext = data.setdefault("NSExtension", {})
    cur = ext.get("NSExtensionPointIdentifier")
    if cur != mode:
        ext["NSExtensionPointIdentifier"] = mode
        with open(p, "wb") as f:
            plistlib.dump(data, f, sort_keys=False)
        print(f"[fix] Widget: {cur} -> {mode}")
    else:
        print(f"[ok] Widget: 已是 {mode}")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    patch_activity_models(root)
    patch_carplay_scene(root)
    patch_widget_point(root)
    print("== 预处理完成 ==")


if __name__ == "__main__":
    main()
