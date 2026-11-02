#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SwiftUI 静态校验器（本地无 Swift 编译器时使用）

背景
----
v2.25 的 CI 连续失败，根因有两类，都不是"编译器抽风"：

  1) ViewModifier 里的 @Binding 没加 $ 前缀
     .sheet(item: poiDetail)      → 期望 Binding<Poi?>，实际传了 Poi?
     .alert(isPresented: showXxx) → 期望 Binding<Bool>，实际传了 Bool
     这类错误只在"修饰符内部"出现，因为 ContentView 里 @State 传进去时自动是 Binding。

  2) 修饰符内部引用了外部 @State，但没在 struct 上声明对应 @Binding
     例：SheetGroup3Modifier 里用了 editPoi，却只在 SheetGroup2Modifier 声明过。

本脚本只做这两类高价值检查（宁可漏报，不可误报 —— 误报会让脚本失去意义）：
  A. 弹窗 API 的 isPresented/item 参数是否漏了 $
  B. Modifier body 内引用了「本 struct 未声明、且不是全局类型/闭包参数」的标识符
  C. .modifier(XxxModifier(...)) 实参名与结构体成员是否一一对应

用法：python3 .ci/swift_lint.py [工程根目录]
"""
import re
import sys
import os

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(ROOT, "MotoNav")

# 全局可见的类型/值（SwiftUI、Foundation、以及工程内自定义的顶层类型）
GLOBAL_NAMES = {
    # SwiftUI 基础
    "AnyView", "View", "Text", "Button", "Image", "Color", "Font", "Spacer", "Divider",
    "Toggle", "Picker", "Section", "List", "NavigationStack", "NavigationView", "NavigationLink",
    "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "LazyVGrid", "ScrollView", "ForEach",
    "Group", "EmptyView", "TextField", "SecureField", "Label", "Link", "Menu", "Gauge",
    "ProgressView", "Slider", "Stepper", "DatePicker", "ColorPicker", "ShareLink",
    # 修饰符
    "Binding", "State", "EnvironmentObject", "Environment", "Published", "AppStorage",
    "StateObject", "ObservedObject", "FocusState", "Namespace", "Transaction",
    # Foundation / 基础类型
    "String", "Int", "Int64", "Double", "Bool", "CGFloat", "Date", "URL", "UUID", "Data",
    "Task", "DispatchQueue", "UserDefaults", "NotificationCenter", "UIApplication", "Notification",
    "Result", "Optional", "Array", "Dictionary", "Set", "Any", "AnyObject", "Error",
    "CLLocationCoordinate2D", "CLLocationManager", "CLLocation", "MKCoordinateRegion",
    # 枚举/类型名（工程内）
    "Poi", "PoiType", "PoiDetailSheet", "PoiEditSheet", "VoiceSettingsSheet", "FootprintSheet",
    "CameraTapSheet", "CameraCandidate", "CameraSyncService", "CameraSyncResult",
    "OfflineMapSheet", "TeamRideSheet", "PoliceCamera", "CameraKind", "PlaceLabel",
    "MapViewRepresentable", "SearchHit", "RouteLink", "RouteWaypoint", "AppModel",
    "FootprintStore", "OfflineMapManager", "TeamRide", "PoliceCameraStore", "AppSecrets",
    "AmapTileRenderer", "MapGeo", "CoordConv", "PlaceShare", "AppearanceMode",
    "CommonPlaceSlot", "TapPlaceInfo", "CompassState", "ActivityModels",
    # 常用成员名（SwiftUI 组件成员）
    "body", "value", "index", "item", "id", "content", "self", "Content",
}


def strip_comments(text: str) -> str:
    out = []
    in_block = False
    for line in text.split("\n"):
        s = line
        if in_block:
            idx = s.find("*/")
            if idx == -1:
                out.append("")
                continue
            s = s[idx + 2:]
            in_block = False
        s = re.sub(r'"(?:[^"\\]|\\.)*"', '""', s)
        idx = s.find("//")
        if idx != -1:
            s = s[:idx]
        if "/*" in s:
            before, rest = s.split("/*", 1)
            if "*/" in rest:
                s = before + rest.split("*/", 1)[1]
            else:
                s = before
                in_block = True
        out.append(s)
    return "\n".join(out)


def find_modifier_structs(lines):
    res = []
    for i, l in enumerate(lines):
        m = re.match(r"\s*(?:private\s+|fileprivate\s+)?struct\s+(\w+)\s*:\s*ViewModifier", l)
        if m:
            name = m.group(1)
            depth = 0
            end = i
            for j in range(i, len(lines)):
                depth += lines[j].count("{") - lines[j].count("}")
                if depth <= 0:
                    end = j
                    break
            res.append((name, i, end))
    return res


def collect_members(lines, start, end):
    members = set()
    for i in range(start, min(end + 1, len(lines))):
        l = lines[i]
        m = re.match(r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:private\s+|fileprivate\s+)?(?:let|var)\s+(\w+)\s*:", l)
        if m:
            members.add(m.group(1))
    return members


def collect_closure_params(lines, start, end):
    """收集 body 区域内闭包参数名（{ p in ... } 里的 p）。"""
    params = set()
    for i in range(start, min(end + 1, len(lines))):
        for m in re.finditer(r"\{\s*([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s+in\b", lines[i]):
            for p in m.group(1).split(","):
                params.add(p.strip())
    return params


def collect_locals(lines, start, end):
    """收集 body 区域内 let/var 局部声明的名字。"""
    locs = set()
    for i in range(start, min(end + 1, len(lines))):
        m = re.match(r"\s*(?:let|var)\s+(\w+)", lines[i])
        if m:
            locs.add(m.group(1))
        # 闭包参数：{ type, name, lat, lon, r in
        for mm in re.finditer(r"\{\s*([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s+in\b", lines[i]):
            for p in mm.group(1).split(","):
                locs.add(p.strip())
    return locs


def lint_binding_dollar(lines):
    """A. 检查弹窗/输入框 API 的参数是否漏了 $。

    漏写 $ 的三类 API：
      .sheet(item: X) / .sheet(isPresented: X) / .alert(isPresented: X)
      .confirmationDialog(isPresented: X)
      TextField(_:text: X) / SecureField(_:text: X) / TextEditor(text: X)
    全部要求 Binding<T>，在 ViewModifier 里必须写 $X。
    """
    problems = []
    pat_sheet_item = re.compile(r"\.sheet\(\s*item:\s*(\w+)")
    pat_presented = re.compile(r"isPresented:\s*(\w+)")
    pat_textfield = re.compile(r"\b(?:TextField|SecureField)\s*\(\s*\"[^\"]*\"\s*,\s*text:\s*(\w+)")
    pat_texteditor = re.compile(r"\bTextEditor\s*\(\s*text:\s*(\w+)")
    for name, s, e in find_modifier_structs(lines):
        for i in range(s, min(e + 1, len(lines))):
            l = lines[i]
            for rx in (pat_sheet_item, pat_presented, pat_textfield, pat_texteditor):
                for mm in rx.finditer(l):
                    ident = mm.group(1)
                    if ident in ("true", "false", "Binding"):
                        continue
                    problems.append((i + 1, name, f"绑定参数 '{ident}' 缺少 $（应写 ${ident}）"))
    return problems


def lint_closure_labels(lines):
    """E. 检查闭包调用是否多写了参数标签。

    形如 `var onAddPoiAtPending: (PoiType) -> Void` 的闭包成员，
    调用时不能写 `onAddPoiAtPending(type: x)` —— Swift 的无标签闭包类型
    调用只接受位置参数，写了 label 会报 "extraneous argument label"。
    """
    problems = []
    # 收集所有 "var name: (Types) -> Ret" 形式的闭包成员
    closure_types = {}
    for i, l in enumerate(lines):
        m = re.match(r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:private\s+|fileprivate\s+)?var\s+(\w+)\s*:\s*\(([^)]*)\)\s*->", l)
        if m:
            closure_types[m.group(1)] = m.group(2)
    if not closure_types:
        return problems
    for i, l in enumerate(lines):
        for name, types in closure_types.items():
            # 只报"有多个参数"的闭包（单参数闭包写 label 也可能合法）
            if "," not in types:
                continue
            for mm in re.finditer(re.escape(name) + r"\s*\(\s*(\w+)\s*:", l):
                problems.append((i + 1, "-", f"闭包 '{name}' 不接受参数标签 '{mm.group(1)}:'（应写 {name}(值)）"))
    return problems


def lint_undeclared_refs(lines):
    problems = []
    for name, s, e in find_modifier_structs(lines):
        members = collect_members(lines, s, e)
        locals_ = collect_locals(lines, s, e)
        cparams = collect_closure_params(lines, s, e)
        body_start = None
        for i in range(s, min(e + 1, len(lines))):
            if re.match(r"\s*func\s+body\s*\(", lines[i]):
                body_start = i
                break
        if body_start is None:
            continue
        for i in range(body_start, min(e + 1, len(lines))):
            l = lines[i]
            if l.strip().startswith("//"):
                continue
            l = re.sub(r'"(?:[^"\\]|\\.)*"', '""', l)
            # 去掉 label: 与方法名，只留裸标识符
            l = re.sub(r"\b\w+\s*:\s*", " ", l)
            l = re.sub(r"\.\w+", " ", l)          # 去掉 .member
            l = re.sub(r"\bself\.", " ", l)
            for ident in re.findall(r"(?<![\w.$])([A-Za-z_]\w*)", l):
                if ident in members or ident in locals_ or ident in cparams:
                    continue
                if ident in GLOBAL_NAMES:
                    continue
                if ident.islower() and len(ident) <= 2:
                    continue
                # 全小写的短标识符多半是闭包内局部量；只对「首字母大写」严格报
                if not ident[0].isupper():
                    continue
                problems.append((i + 1, name, f"引用了未声明的 '{ident}'"))
    return problems


def lint_modifier_calls(lines):
    structs = {n: (s, e) for n, s, e in find_modifier_structs(lines)}
    problems = []
    for i, l in enumerate(lines):
        m = re.search(r"\.modifier\(\s*(\w+)\s*\(", l)
        if not m:
            continue
        sname = m.group(1)
        if sname not in structs:
            continue
        s, e = structs[sname]
        members = collect_members(lines, s, e)
        chunk = l
        j = i
        while chunk.count("(") > chunk.count(")") and j + 1 < len(lines):
            j += 1
            chunk += "\n" + lines[j]
        # 取出「结构体名之后」那个 '(' 的内容：.modifier(XxxModifier(a: 1, b: 2))
        # 注意 chunk.index("(") 会命中 .modifier( 的括号，所以要用正则定位结构体名后的括号
        mm_open = re.search(r"\.modifier\(\s*\w+\s*\(", chunk)
        if not mm_open:
            continue
        inner = chunk[mm_open.end():]
        depth = 0
        flat = []
        buf = ""
        for ch in inner:
            if ch in "([{":
                depth += 1
                if depth == 1:
                    continue
            elif ch in ")]}":
                depth -= 1
                if depth == 0:
                    continue
            if depth == 0 and ch == ",":
                flat.append(buf)
                buf = ""
                continue
            buf += ch
        if buf.strip():
            flat.append(buf)
        args = []
        for a in flat:
            a = a.strip()
            if not a:
                continue
            # 实参形式：label: value  或  $value  或  value
            mm = re.match(r"(\w+)\s*:\s*(.*)$", a, re.S)
            if mm:
                args.append(mm.group(1))
            else:
                # 无 label：取最后一个标识符（$poiDetail → poiDetail）
                ids = re.findall(r"\$?(\w+)", a)
                args.append(ids[-1] if ids else None)
        for a in args:
            if a is None:
                continue
            if a not in members:
                problems.append((i + 1, sname, f"实参 '{a}' 不是结构体成员"))
        for mem in sorted(members):
            if mem == "model":
                continue
            if mem not in args:
                problems.append((i + 1, sname, f"结构体成员 '{mem}' 未在调用处传入"))
    return problems


def lint_duplicate_members(lines, filename):
    """D. 同一 struct 内重复定义同名成员（Swift 编译错误：invalid redeclaration）。"""
    problems = []
    # 按 struct 切分（任意 struct/enum/extension/class）
    for i, l in enumerate(lines):
        m = re.match(r"\s*(?:private\s+|fileprivate\s+|public\s+|internal\s+)?(?:struct|class|enum|extension)\s+(\w+)", l)
        if not m:
            continue
        sname = m.group(1)
        depth = 0
        end = i
        for j in range(i, len(lines)):
            depth += lines[j].count("{") - lines[j].count("}")
            if depth <= 0:
                end = j
                break
        seen = {}
        for k in range(i, min(end + 1, len(lines))):
            mm = re.match(r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:private\s+|fileprivate\s+|public\s+)?(?:static\s+)?(?:let|var|func)\s+(\w+)", lines[k])
            if not mm:
                continue
            name = mm.group(1)
            # 只统计 struct 体第一层（depth == 1），
            # 跳过嵌套的闭包/函数体（depth >= 2）
            d = 0
            for x in range(i, k):
                d += lines[x].count("{") - lines[x].count("}")
            if d != 1:
                continue
            if name in seen:
                # Swift 允许同名重载（参数类型不同），只有"签名完全相同"才是重复定义。
                # 这里比较声明行的完整文本（去空白）来判断。
                sig_now = re.sub(r"\s+", " ", lines[k].strip())
                sig_prev = re.sub(r"\s+", " ", lines[seen[name] - 1].strip())
                # let/var 互斥（同名 let 与 var 也是重复定义）
                kind_now = "var" if sig_now.startswith("var") else ("let" if sig_now.startswith("let") else "func")
                kind_prev = "var" if sig_prev.startswith("var") else ("let" if sig_prev.startswith("let") else "func")
                same_kind = (kind_now == kind_prev)
                if sig_now == sig_prev and same_kind:
                    problems.append((k + 1, sname, f"重复定义 '{name}'（首次在第 {seen[name]} 行）"))
            else:
                seen[name] = k + 1
    return problems


def main():
    files = [f for f in os.listdir(SRC) if f.endswith(".swift")]
    all_problems = []
    for f in sorted(files):
        path = os.path.join(SRC, f)
        raw = open(path, encoding="utf-8").read()
        lines = strip_comments(raw).split("\n")
        if not find_modifier_structs(lines):
            # 非修饰符文件也要查重复定义
            for prob in lint_duplicate_members(lines, f) + lint_closure_labels(lines):
                all_problems.append((f,) + prob)
            continue
        for prob in (lint_binding_dollar(lines) + lint_undeclared_refs(lines)
                     + lint_modifier_calls(lines) + lint_duplicate_members(lines, f)
                     + lint_closure_labels(lines)):
            all_problems.append((f,) + prob)

    seen = set()
    uniq = []
    for p in all_problems:
        k = (p[0], p[1], p[3])
        if k in seen:
            continue
        seen.add(k)
        uniq.append(p)

    if not uniq:
        print("✅ swift_lint: 未发现问题")
        return 0
    print(f"❌ swift_lint: {len(uniq)} 个问题")
    for f, ln, sname, msg in uniq:
        print(f"  {f}:{ln}  [{sname}]  {msg}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
