//
//  DraggableFloat.swift
//  MotoNav
//
//  v2.27 从 ContentView.swift 拆出（优化建议 #2）
//
//  可拖动浮层
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
import UIKit

struct DraggableFloat<Content: View>: View {
    let key: String
    var lockX: Bool = false
    /// v2.23 顶部锁定：卡片顶部始终贴屏幕顶，只能往下拉，不能往上拉出屏幕；
    /// 且下次启动默认回到顶部（defaultPosY 即顶部位置）。
    var topLocked: Bool = false
    /// v2.23 底部锚定：pos.y 表示卡片**底边**所在位置（卡片向上生长）。
    /// 底部大卡片（路线规划下卡）用这个，否则 .position() 按中心定位会把
    /// 卡片下半截（"开始导航"按钮）推到屏幕外，点不到。
    var bottomAnchor: Bool = false
    var deleteLabel: String? = nil
    var onSwipeLeft: (() -> Void)? = nil
    @ViewBuilder let content: Content
    @State private var pos: CGPoint
    @State private var initialX: CGFloat
    @State private var dragging = false
    @State private var deleting = false
    @State private var dragOffset: CGFloat = 0
    /// v1.99 拖动起点（手指按下时的中心点）：旧版直接把中心设为手指位置，
    /// 一按下去整块就"跳"到手指下，滑动时始终慢半拍、像甩不动的橡皮筋
    @State private var dragStartPos: CGPoint? = nil
    /// v2.23 顶部锁定时卡片的顶部位置（相对屏高），下拉可更低、上拉不可更高
    @State private var defaultTopY: CGFloat = 0.1
    /// v2.23 卡片内容实测尺寸：用于把卡片完整钳制在屏幕内（防止底部按钮被裁掉）
    @State private var contentSize: CGSize = .zero

    init(key: String, defaultPos: CGPoint, lockX: Bool = false, topLocked: Bool = false,
         bottomAnchor: Bool = false,
         deleteLabel: String? = nil,
         onSwipeLeft: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.key = key
        self.lockX = lockX
        self.topLocked = topLocked
        self.bottomAnchor = bottomAnchor
        self.deleteLabel = deleteLabel
        self.onSwipeLeft = onSwipeLeft
        self.content = content()
        let x = UserDefaults.standard.object(forKey: "\(key).x") as? Double
        let y = UserDefaults.standard.object(forKey: "\(key).y") as? Double
        // v1.99 缩放/定位按钮默认位置改到"搜索框右上方"：一次性作废旧坐标，
        // 否则装过旧版的手机会继续用存储在 UserDefaults 里的右上角位置
        let posVersion = UserDefaults.standard.integer(forKey: "\(key).posV")
        let stale = key == "zoom" && posVersion < 2
        if stale { UserDefaults.standard.set(2, forKey: "\(key).posV") }
        let savedX = stale ? nil : x
        let savedY = stale ? nil : y
        // v1.97 兜底钳制：历史拖动位置可能落在屏幕外（如旧版缩放键 6%），这里拉回可视区
        // v2.23 顶部锁定：y 一律取 defaultPos.y（顶部），历史位置不再生效，
        // 保证"下次打开软件卡片顶部仍在屏幕顶部"。
        let px = min(0.96, max(0.04, savedX ?? defaultPos.x))
        let py: CGFloat
        if topLocked {
            py = defaultPos.y
        } else {
            py = min(0.93, max(0.10, savedY ?? defaultPos.y))
        }
        _pos = State(initialValue: CGPoint(x: px, y: py))
        _defaultTopY = State(initialValue: defaultPos.y)
        _initialX = State(initialValue: px)
    }

    /// v2.23 计算卡片中心的最终 y 坐标
    /// - 底部锚定：pos.y 是底边位置 → 中心 = 底边 - 半个高度
    /// - 顶部锁定：pos.y 是顶部位置 → 中心 = 顶部 + 半个高度
    /// - 其余：pos.y 直接是中心，但会被钳制到"卡片完整可见"的范围内
    private func clampedY(_ geoSize: CGSize) -> CGFloat {
        let margin: CGFloat = 8
        let h = contentSize.height
        // 注意：入参已经是 CGSize（不是装着 CGSize 的 geo），不能再取 .size
        let screenH = geoSize.height
        guard h > 0, screenH > 0 else { return pos.y * screenH }

        var center: CGFloat
        if bottomAnchor {
            center = pos.y * screenH - h / 2
        } else if topLocked {
            center = pos.y * screenH + h / 2
        } else {
            center = pos.y * screenH
        }
        // 钳制：卡片完整可见（上边不越界，下边不越界）
        let minCenter = margin + h / 2
        let maxCenter = max(minCenter, screenH - margin - h / 2)
        return min(max(center, minCenter), maxCenter)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .trailing) {
                // v1.81.4 红色删除按钮块（模仿高德样式）：固定宽度、高度同卡片、仅左拉时出现
                if let lbl = deleteLabel {
                    HStack(spacing: 0) {
                        Spacer()
                        Text(lbl)
                            .font(.headline.bold())
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: 92)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .opacity(dragOffset < -8 ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: dragOffset < -8)
                }
                content
                    .offset(x: dragOffset)
                    // v2.23 实测内容尺寸：底部锚定/钳制都要用
                    .background(
                        GeometryReader { cg in
                            Color.clear
                                .onAppear { contentSize = cg.size }
                                .onChange(of: cg.size) { _, newSize in contentSize = newSize }
                        }
                    )
            }
            // v2.23 定位修正：
            //  ① bottomAnchor：pos.y 表示卡片**底边**，卡片向上生长
            //     （否则 .position() 按中心定位，高卡片下半截会掉出屏幕 → "开始导航"点不到）
            //  ② 通用钳制：保证卡片完整落在屏幕内（上下各留 8pt 安全边）
            .position(x: pos.x * geo.size.width, y: clampedY(geo.size))
            .shadow(color: .black.opacity(dragging ? 0.3 : 0.12), radius: 8, y: 3)
            .scaleEffect(dragging ? 1.08 : 1.0)
            .animation(.easeOut(duration: 0.12), value: dragging)
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        if deleteLabel != nil, v.translation.width < -8,
                           abs(v.translation.width) > abs(v.translation.height) {
                            // 左滑删除模式：卡片跟随左移，露出红色删除卡
                            deleting = true
                            dragOffset = v.translation.width
                        } else {
                            // 正常拖动：按位移增量移动，手指与卡片严格同步（不再跳到手指中心）
                            deleting = false
                            dragOffset = 0
                            dragging = true
                            let base = dragStartPos ?? pos
                            if dragStartPos == nil { dragStartPos = base }
                            let w = max(1, geo.size.width)
                            let h = max(1, geo.size.height)
                            var newY = min(0.99, max(0.02, base.y + v.translation.height / h))
                            if topLocked {
                                // v2.23 顶部锁定：pos.y 是卡片**顶部**位置，
                                // 只能往下拉，不能往上拉把顶部顶出屏幕
                                newY = max(defaultTopY, newY)
                            } else if bottomAnchor {
                                // v2.23 底部锚定：pos.y 是卡片**底边**位置，
                                // 往上拖不能把卡片整体推出屏幕顶（留半个身位）
                                newY = min(0.99, max(0.12, newY))
                            }
                            pos = CGPoint(
                                x: lockX ? initialX : min(0.96, max(0.04, base.x + v.translation.width / w)),
                                y: newY)
                        }
                    }
                    .onEnded { v in
                        dragging = false
                        dragStartPos = nil
                        if deleting {
                            // 左拉过卡片一半宽度即完成删除
                            let cardW = geo.size.width - 28
                            if dragOffset < -cardW * 0.5 {
                                onSwipeLeft?()
                            } else {
                                withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                            }
                        } else if let onSwipeLeft = onSwipeLeft,
                                  v.translation.width < -80,
                                  abs(v.translation.width) > abs(v.translation.height) {
                            onSwipeLeft()
                        } else if !topLocked {
                            UserDefaults.standard.set(pos.x, forKey: "\(key).x")
                            UserDefaults.standard.set(pos.y, forKey: "\(key).y")
                        }
                    }
            )
        }
    }
}

// =============================================================================
// v1.99 三个数据面板：足迹 / 离线地图 / 组队骑行
// =============================================================================

/// 足迹列表：里程、时长、均速/最高速，支持回放、导出 GPX、删除
