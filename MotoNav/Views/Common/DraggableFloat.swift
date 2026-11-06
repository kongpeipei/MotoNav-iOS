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

/// v2.34 重置全部悬浮控件位置的通知（设置页"重置悬浮控件位置"按钮发出）
extension Notification.Name {
    static let floatResetAll = Notification.Name("floatResetAll")
}

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
    /// v2.48 卡片屏幕框回调：规划卡把 content 在屏幕坐标系里的真实 rect 回传给地图，
    /// 路线全览按"卡片实际遮挡到哪"留白（不依赖 6%/3% 屏高比例的假设）。
    var onFrameChange: ((CGRect) -> Void)? = nil
    /// v2.51 额外底部占位（键盘高度）：键盘弹起时卡片整体坐在键盘上方，
    /// 而不是像旧版那样手写 `.offset(y: -300)` —— 手写偏移不受钳制约束，会把卡片顶出屏幕。
    var extraBottomInset: CGFloat = 0
    /// v2.54 底部避让：底部另有常驻卡片（规划下卡 / 行程卡）时，把它占掉的高度传进来，
    /// 让本浮层被钳制在卡片上沿以上，避免"按钮露半个、点不到"。
    var avoidBottom: CGFloat = 0
    /// v2.58 顶部避让：屏幕上方有必须留白的东西（首页定位点恒在屏幕正中）时，
    /// 传它下沿的 y，本浮层顶边不得高于它 —— 即"卡片去躲那个点"，而不是把点挪走。
    /// 传 0 表示不限制（默认）。
    var avoidTop: CGFloat = 0
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
    /// v2.34 默认位置快照（复位通知时恢复用）
    @State private var defaultPos0: CGPoint = .zero

    init(key: String, defaultPos: CGPoint, lockX: Bool = false, topLocked: Bool = false,
         bottomAnchor: Bool = false,
         deleteLabel: String? = nil,
         onSwipeLeft: (() -> Void)? = nil,
         onFrameChange: ((CGRect) -> Void)? = nil,
         extraBottomInset: CGFloat = 0,
         avoidBottom: CGFloat = 0,
         avoidTop: CGFloat = 0,
         @ViewBuilder content: () -> Content) {
        self.key = key
        self.lockX = lockX
        self.topLocked = topLocked
        self.bottomAnchor = bottomAnchor
        self.deleteLabel = deleteLabel
        self.onSwipeLeft = onSwipeLeft
        self.onFrameChange = onFrameChange
        self.extraBottomInset = extraBottomInset
        self.avoidBottom = avoidBottom
        self.avoidTop = avoidTop
        self.content = content()
        let x = UserDefaults.standard.object(forKey: "\(key).x") as? Double
        let y = UserDefaults.standard.object(forKey: "\(key).y") as? Double
        // v1.99 缩放/定位按钮默认位置改到"搜索框右上方"：一次性作废旧坐标，
        // 否则装过旧版的手机会继续用存储在 UserDefaults 里的右上角位置
        let posVersion = UserDefaults.standard.integer(forKey: "\(key).posV")
        // v2.56 地点卡默认位置从"屏幕中部"改到"贴底"：旧坐标必须一并作废，
        // 否则装过旧版的手机会继续按记忆里的 0.66 屏高渲染，遮挡问题原样复现
        // v2.58 又挪了两组控件：缩放组 0.655→0.26（归位右上角）、左侧竖排 0.50→0.72（让开中轴）、
        // 导航底卡再作废一次（旧版 0.66 屏高的记忆值会让"继续导航"悬在屏幕中间）。
        // v2.59 版本号整体推进一档：旧版作废时只写了版本号、没清坐标值，
        // 已经在手机上跑过旧版的设备 posV 已经是 1，再也不会进 stale。
        // 推一档才能让它们重新作废一次，并借这次真正的清值。
        let stale = (key == "zoom" && posVersion < 4)
            || (key == "tapplace" && posVersion < 2)
            || (key == "tipcard" && posVersion < 2)
            || (key == "exitnav2" && posVersion < 3)
            || (key == "navside" && posVersion < 2)
            // v2.58 规划页下卡（方案卡）补作废：它的 defaultPos 从 v2.23 起就是 0.97，
            // 但作废表里一直没有这个 key —— 只要历史上有一次被拖到屏幕中部，
            // 之后每次规划都停在半空（本轮用户截图里卡在 66% 屏高就是这个）。
            || (key == "routeplanbottom" && posVersion < 2)
            // v2.59 搜索卡从"底边锚定 0.97"改成"中心定位 0.88"，语义变了，
            // 记忆里的 0.97（旧语义=底边）直接套到中心定位会把卡片整体推下去半个卡高 —— 必须作废
            || (key == "bottommain" && posVersion < 2)
        if stale {
            let v = key == "zoom" ? 4 : (key == "exitnav2" ? 3 : 2)
            UserDefaults.standard.set(v, forKey: "\(key).posV")
            // v2.59 真正把旧坐标清掉。旧版这里只推进了版本号，UserDefaults 里的 y 原样留着：
            // 作废只在"当次显示"生效（用 defaultPos），下一次进页面 posVersion 已经是 1、
            // 不再 stale，又把旧 y 读回来 —— 用户实机里方案卡/地点卡第二次以后又回到
            // 屏幕中部，就是这条造成的。作废必须同时把存储值改写为默认位置。
            UserDefaults.standard.set(Double(defaultPos.x), forKey: "\(key).x")
            UserDefaults.standard.set(Double(defaultPos.y), forKey: "\(key).y")
        }
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
            // v2.58 底锚定卡片（地点卡 / 行程卡 / 导航底卡）放开到 0.97：
            // 旧的 0.93 上限会把"贴底"再往上拉 35pt，卡片离 home indicator 空出一截，
            // 看着不像贴底。普通卡片仍保持 0.93，避免压住底部 tab。
            py = min(bottomAnchor ? 0.97 : 0.93, max(0.10, savedY ?? defaultPos.y))
        }
        _pos = State(initialValue: CGPoint(x: px, y: py))
        _defaultTopY = State(initialValue: defaultPos.y)
        _initialX = State(initialValue: px)
        _defaultPos0 = State(initialValue: defaultPos)
    }

    /// v2.23 计算卡片中心的最终 y 坐标
    /// - 底部锚定：pos.y 是底边位置 → 中心 = 底边 - 半个高度
    /// - 顶部锁定：pos.y 是顶部位置 → 中心 = 顶部 + 半个高度
    /// - 其余：pos.y 直接是中心，但会被钳制到"卡片完整可见"的范围内
    private func clampedY(_ geo: GeometryProxy) -> CGFloat {
        let gap: CGFloat = 6
        let h = contentSize.height
        let screenH = geo.size.height
        // v2.59 兜底：内容尺寸还没测到时旧版直接返回 pos.y * screenH —— 那是"中心"语义，
        // 对 bottomAnchor 的卡片就等于把底边当中心，下半截整个掉出屏幕
        //（v2.59 搜索卡实机就是这副样子）。这里改成按锚点语义 + 屏内钳制。
        guard h > 0, screenH > 0 else {
            // v2.60 内容高度未知时不再信任 pos.y。pos.y 可能是旧语义的记忆值、
            // 也可能是拖动残留（拖动上限只钳到 0.99），拿它当中心/底边都会把卡片
            // 放到屏幕外 —— 用户实机里搜索卡整个沉到 tab 条以下就是这条。
            // 这种时候只认 defaultPos，至少保证卡片出现在设计位置上。
            let fallbackH: CGFloat = 64
            let raw = bottomAnchor ? defaultPos.y * screenH - fallbackH / 2
                                   : defaultPos.y * screenH
            return min(screenH - fallbackH / 2, max(fallbackH / 2, raw))
        }

        var center: CGFloat
        if bottomAnchor {
            center = pos.y * screenH - h / 2
        } else if topLocked {
            center = pos.y * screenH + h / 2
        } else {
            center = pos.y * screenH
        }
        // v2.50 钳制到安全区：卡片不进状态栏/灵动岛、不压 home indicator。
        // 用 geo.safeAreaInsets 而不是 UIKit 的窗口安全区——它和 geo 的坐标原点同源，
        // 无论这个 GeometryReader 是"安全区内（返回 0）"还是"已被 ignoresSafeArea 拉到全屏
        // （返回真实 47/34）"，都不会出现双重偏移。
        let safe = geo.safeAreaInsets
        let usableTop = safe.top + gap
        // 键盘占位：卡片底边不得超过键盘上沿。
        // 取 safe.bottom 与键盘高度中的较大者，避免"键盘已被系统算进安全区"时被扣两次
        let bottomInset = max(safe.bottom, max(0, extraBottomInset))
        // v2.54 底部常驻卡片避让（规划下卡 / 行程卡）
        let cardAvoid = max(0, avoidBottom)
        let usableBottom = screenH - bottomInset - gap - cardAvoid
        // v2.58 顶部避让：顶边不得高于 avoidTop（center - h/2 >= avoidTop）
        let keepBelow = avoidTop + h / 2
        let minCenter = max(usableTop + h / 2, keepBelow)
        // 卡片比可用区还高时顶对齐（内容侧另有高度上限兜底），不把卡片推到屏幕外
        let maxCenter = max(minCenter, usableBottom - h / 2)
        // v2.60 最终保险：无论上面怎么算，卡片底边一律不许越过 home indicator
        //（历史上出现过多条路径叠加后整卡掉出屏幕的情况）
        let hardMax = max(minCenter, screenH - h / 2 - 8)
        return min(max(center, minCenter), min(maxCenter, hardMax))
    }

    /// v2.50 横向钳制：按卡片**实际宽度**保证左右不出屏。
    ///
    /// 旧版只把pos.x按屏宽比例钳到 4%~96%，宽卡片（规划卡 366pt）中心放到 0.04
    /// 时左边缘会到 -150pt，一半卡片在屏幕外。高德的做法是浮层四周恒留 8pt。
    private func clampedX(_ geo: GeometryProxy) -> CGFloat {
        let gap: CGFloat = 8
        let w = contentSize.width
        let screenW = geo.size.width
        let raw = pos.x * screenW
        guard w > 0, screenW > 0 else { return raw }
        let minX = gap + w / 2
        let maxX = max(minX, screenW - gap - w / 2)
        return min(max(raw, minX), maxX)
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
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .opacity(dragOffset < -8 ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: dragOffset < -8)
                }
                content
                    // v2.50 内容高度上限 = 安全区之间可用高度：
                    // 超高卡片（内容多的面板、极简模式大字）不再被推到屏幕外，
                    // 内部是 ScrollView 的卡片会自动变成滚动
                    .frame(maxHeight: max(200, geo.size.height
                                          - geo.safeAreaInsets.top
                                          - max(geo.safeAreaInsets.bottom, max(0, extraBottomInset)) - 12))
                    .offset(x: dragOffset)
                    // v2.23 实测内容尺寸：底部锚定/钳制都要用
                    .background(
                        GeometryReader { cg in
                            Color.clear
                                .onAppear {
                                    contentSize = cg.size
                                    onFrameChange?(cg.frame(in: .global))
                                }
                                // 只在尺寸变化（卡片出现/内容变高）时上报：
                                // 拖动卡片不触发地图重算，避免拖拽中地图反复重 fit 抖动。
                                .onChange(of: cg.size) { _, newSize in
                                    contentSize = newSize
                                    onFrameChange?(cg.frame(in: .global))
                                }
                        }
                    )
            }
            // v2.23 定位修正：
            //  ① bottomAnchor：pos.y 表示卡片**底边**，卡片向上生长
            //     （否则 .position() 按中心定位，高卡片下半截会掉出屏幕 → "开始导航"点不到）
            //  ② 通用钳制：保证卡片完整落在屏幕内（上下各留 8pt 安全边）
            .position(x: clampedX(geo), y: clampedY(geo))
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
                            // v2.56 横向手势不跟随纵向：
                            // 用户想"右滑一下卡片"时手不可能完全水平，斜向位移里的那点 height
                            // 每次都写进 pos.y，几次之后卡片就从顶部缓慢掉到屏幕中间（规划页
                            // 起终点卡压住方案卡、两张卡叠成一片就是这么来的）。
                            // 判定：横向位移超过纵向 2 倍 → 视为纯横向手势，纵向保持不动。
                            let horizontalSwipe = abs(v.translation.width) > abs(v.translation.height) * 2
                            var newY = horizontalSwipe
                                ? base.y
                                : min(0.99, max(0.02, base.y + v.translation.height / h))
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
            // v2.34 收到"重置悬浮控件位置"通知：重新读 UserDefaults（已被按钮清空）并回默认位
            .onReceive(NotificationCenter.default.publisher(for: .floatResetAll)) { _ in
                let rx = UserDefaults.standard.object(forKey: "\(key).x") as? Double
                let ry = UserDefaults.standard.object(forKey: "\(key).y") as? Double
                pos = CGPoint(
                    x: min(0.96, max(0.04, rx ?? defaultPos0.x)),
                    y: topLocked ? defaultPos0.y
                       : min(0.93, max(0.10, ry ?? defaultPos0.y)))
            }
        }
    }
}

// =============================================================================
// v1.99 三个数据面板：足迹 / 离线地图 / 组队骑行
// =============================================================================

/// 足迹列表：里程、时长、均速/最高速，支持回放、导出 GPX、删除
