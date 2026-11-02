//
//  WebPageFetcher.swift
//  MotoNav
//
//  v2.27 新增：离屏 WKWebView 抓取器
//
//  为什么需要它
//  ------------
//  合肥市公安局网站（gaj.hefei.gov.cn）启用了"加速乐"一类的 JS 反爬：
//  首次请求返回一段混淆 JS，它执行后设置 __jsl_clearance_s Cookie 并刷新页面，
//  才给出真正的正文。
//
//  实测（v2.26 在沙箱里逐个试过）：
//  · URLSession + 移动端 UA        → 521 + 挑战页，拿不到正文
//  · 计算挑战 cookie 后带 Cookie 重试 → cookie 每次都变（绑定 IP/UA/时间戳），仍然失败
//  · 无头 Chromium 等 24 秒          → 仍停在挑战页
//
//  原因很直接：**纯 HTTP 客户端过不了需要执行 JS 的挑战**。
//  但 iOS 上有 WKWebView —— 它带完整 JS 引擎，能正常跑过挑战。
//  所以正确解法是：让 WKWebView 真的去访问页面，等它跑完 JS，再把 DOM 取出来。
//
//  实现要点
//  --------
//  1. 用 UIWindow + WKWebView 承载（不能用纯离屏 WKWebView：
//     它在无窗口时可能不执行部分 JS）；
//  2. 监听 didFinish navigation，若页面仍是挑战页（URL 被重定向到同一路径
//     或内容含挑战特征），等待后重试，最多 N 次；
//  3. 页面稳定后用 evaluateJavaScript 取 document.documentElement.outerHTML；
//  4. 全程不阻塞主线程（异步 API）。
//
//  隐私
//  ----
//  只访问公开政务页面，不带任何用户凭据；WKWebView 用独立的
//  WKWebsiteDataStore（不与 App 其它 WebView 共享 Cookie）。
//

import Foundation
import WebKit
import UIKit

/// v2.27 离屏 WebView 抓取器
@MainActor
final class WebPageFetcher: NSObject {
    /// 抓取结果
    enum FetchResult {
        case success(html: String)
        /// 挑战页过不去（站点反爬强度超预期）
        case challengeBlocked
        case failed(String)
    }

    /// 单例（复用同一个 WebView，减少开销）
    static let shared = WebPageFetcher()

    private var webView: WKWebView?
    private var window: UIWindow?
    private var continuation: CheckedContinuation<FetchResult, Never>?
    private var attempts = 0
    private var maxAttempts = 3
    private var currentURL: URL?
    private var timeoutTask: Task<Void, Never>?
    /// 挑战页特征串（命中即认为还没过）
    private static let challengeMarkers = ["jsl_clearance", "__jsl_", "var _0x", "document.cookie=('")

    private override init() {
        super.init()
    }

    /// 抓取一个 URL 的 HTML
    /// - Parameters:
    ///   - url: 目标页面
    ///   - timeout: 总超时（秒）
    ///   - requiresChallenge: 是否需要过 JS 挑战（政务站点传 true）
    func fetch(_ url: URL, timeout: TimeInterval = 25,
               requiresChallenge: Bool = false) async -> FetchResult {
        // 同一时刻只允许一个抓取任务，避免 WebView 状态混乱
        if continuation != nil {
            return .failed("已有抓取任务在进行")
        }
        maxAttempts = requiresChallenge ? 4 : 2
        attempts = 0
        currentURL = url

        return await withCheckedContinuation { cont in
            self.continuation = cont
            self.startLoading(url)
            // 超时兜底：无论加载是否完成，到点就返回失败，不让调用方永久等待
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(.failed("加载超时（\(Int(timeout)) 秒）"))
            }
        }
    }

    // MARK: - 加载

    private func startLoading(_ url: URL) {
        attempts += 1
        let config = WKWebViewConfiguration()
        // 独立数据存储：不影响 App 内其它 WebView，也不带用户凭据
        config.websiteDataStore = .nonPersistent()
        // 允许 JS 执行（挑战页必须）
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = self
        wv.isOpaque = true
        wv.backgroundColor = .white
        wv.isHidden = true

        // 挂在窗口上：纯离屏的 WKWebView 在部分 iOS 版本上不执行 JS
        let win = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        win.isHidden = false
        win.alpha = 0.01
        win.rootViewController = UIViewController()
        win.rootViewController?.view.addSubview(wv)
        win.makeKeyAndVisible()

        self.webView = wv
        self.window = win
        wv.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
    }

    // MARK: - 结果

    private func finish(_ result: FetchResult) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        // 清理 WebView 与窗口
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        window?.isHidden = true
        window = nil
        cont.resume(returning: result)
    }

    /// 判断 HTML 是否仍是挑战页
    private static func isChallenge(_ html: String) -> Bool {
        let head = String(html.prefix(4000))
        return challengeMarkers.contains { head.contains($0) }
    }
}

// MARK: - WKNavigationDelegate

// WKNavigationDelegate 的回调方法本身不是隔离的（协议要求 nonisolated），
// 但 WKWebView 是主线程对象、且本类的状态都在 MainActor 上。
// 这里用 `nonisolated` 实现协议要求，再在内部用 `MainActor.assumeIsolated`
// 回到主线程操作状态 —— 否则 Swift 6 语言模式会把
// "call to main actor-isolated ... in a synchronous nonisolated context" 升级为编译错误。
extension WebPageFetcher: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // WebKit 保证在主线程回调
        MainActor.assumeIsolated {
            self.handleDidFinish(webView)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            self.handleFailure(error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            self.handleFailure(error)
        }
    }

    // MARK: 主线程内的实际处理

    private func handleDidFinish(_ webView: WKWebView) {
        guard continuation != nil else { return }
        // 取当前 DOM
        webView.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''") { [weak self] value, _ in
            Task { @MainActor in
                guard let self, self.continuation != nil else { return }
                let html = (value as? String) ?? ""
                if html.isEmpty {
                    if self.attempts < self.maxAttempts {
                        self.startLoading(self.currentURL ?? URL(string: "about:blank")!)
                    } else {
                        self.finish(.failed("页面内容为空"))
                    }
                    return
                }
                // 还是挑战页 → 等一下再重试（挑战页会自己刷新，但我们主动重试更稳）
                if Self.isChallenge(html) {
                    if self.attempts < self.maxAttempts {
                        // 给挑战页 1.5 秒自己跳转的时间，再重试
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if self.continuation != nil {
                            self.startLoading(self.currentURL ?? URL(string: "about:blank")!)
                        }
                    } else {
                        self.finish(.challengeBlocked)
                    }
                    return
                }
                self.finish(.success(html: html))
            }
        }
    }

    private func handleFailure(_ error: Error) {
        guard continuation != nil else { return }
        let ns = (error as NSError)
        // -999 = cancelled（重试时的主动取消），不算失败
        if ns.code == NSURLErrorCancelled { return }
        finish(.failed(error.localizedDescription))
    }
}
