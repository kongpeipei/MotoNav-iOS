//
//  CommonViews.swift
//  MotoNav
//
//  v2.27 从 ContentView.swift 拆出（优化建议 #2）
//
//  SwipeDeleteRow + CompassDial
//
//  拆分理由：ContentView.swift 一度长到 5896 行，承载了地图层、规划卡、
//  地点卡、导航卡、我的页、设置页、同步提示框 7 大块。行数一多，每次改动都要
//  在全文件里定位，回归风险随行数线性增长；之前连续三次「类型检查超时」
//  就是这么来的。
//
//  工程用 PBXFileSystemSynchronizedRootGroup，新文件自动参与编译，
//  不需要改 project.pbxproj。
//

import SwiftUI

struct SwipeDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Spacer()
                Button {
                    onDelete()
                } label: {
                    Text("删除")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 92)
                .background(Color.red)
            }
            .opacity(offset < -8 ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: offset < -8)
            content
                .offset(x: offset)
        }
        .clipped()
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { v in
                    if v.translation.width < 0 { offset = v.translation.width }
                }
                .onEnded { v in
                    if offset < -46 {
                        onDelete()
                    } else {
                        withAnimation(.spring(duration: 0.3)) { offset = 0 }
                    }
                }
        )
    }
}

/// v1.80 可拖动悬浮控件：位置以 0-1 归一化持久化到 UserDefaults，下次打开还原
/// v1.81.2 支持 onSwipeLeft：向左大幅滑动（>80pt 且横向为主）触发回调关闭，否则正常拖动记忆
/// v1.81.4 支持 lockX：仅上下移动（横向锁定在初始 x）
/// v1.81.4 支持 deleteLabel：左滑时卡片后跟红色"左拉删除"卡（大小同卡片），滑过一半触发删除回调
/// v2.13 指南针表盘（独立子视图）。
///
/// 朝向单独走 `CompassState`：磁力计 10~20Hz，若由 ContentView 直接观察，
/// 每次回调都会让 4000 行的 body 整体重算一次；拆出来以后只有这 56pt 重算。
struct CompassDial: View {
    @ObservedObject var compass: CompassState

    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
            // 红色指北针（随手机朝向旋转）
            Image(systemName: "location.north.fill")
                .font(.title3)
                .foregroundStyle(.red)
                .rotationEffect(.degrees(compass.angle))
            // 四方位：北（上）东（右）南（下）西（左）
            Text("北")
                .font(.caption2.bold())
                .foregroundStyle(.red)
                .offset(y: -20)
            Text("东")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .offset(x: 19)
            Text("南")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .offset(y: 20)
            Text("西")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .offset(x: -19)
        }
        .frame(width: 56, height: 56)
    }
}


// MARK: - v2.25 弹窗修饰符组（拆分以解决类型检查超时）

/// v2.25 把 body 上的 13 个弹窗修饰符拆成 3 个 ViewModifier。
///
/// 为什么必须拆：这些修饰符（6×sheet + 3×confirmationDialog + 4×alert）每个都带
/// 内容闭包，confirmationDialog 还要现场构造 Binding。全部挂在 body 的同一个
/// 表达式上时，Swift 编译器要在一个表达式里同时展开所有闭包 + 底下的地图/设置页，
/// 类型推断超出时间预算，报：
///   "the compiler is unable to type-check this expression in reasonable time"
/// 而且报错行号落在 `var body` 上，离真正原因（弹窗群）很远，极难定位。
///
/// 拆开后：每个 Modifier 只有 4~6 个弹窗，内容闭包在各自作用域内独立推断。
/// 状态用 @Binding 传入、行为用闭包传入，逻辑与原来完全一致。

