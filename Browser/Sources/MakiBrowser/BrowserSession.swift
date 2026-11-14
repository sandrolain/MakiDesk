import AppKit
import Foundation
import WebKit

struct BrowserNavigationState: Sendable {
    var url: URL?
    var title: String?
    var isLoading: Bool
    var canGoBack: Bool
    var canGoForward: Bool
}

/// Owns one `WKWebView` and forwards its events to the store. The store keeps
/// the session alive; the session never owns the model.
@MainActor
final class BrowserTabSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var tabID: UUID
    private(set) var webView: WKWebView!
    private weak var store: BrowserStore?
    private var stateObservations: [NSKeyValueObservation] = []
    private var stateUpdateTask: Task<Void, Never>?

    init(tabID: UUID,
         configuration: WKWebViewConfiguration,
         store: BrowserStore,
         isInspectable: Bool) {
        self.tabID = tabID
        self.store = store
        super.init()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = isInspectable
        observeNavigationState()
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func stop() {
        stateUpdateTask?.cancel()
        stateUpdateTask = nil
        stateObservations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private func observeNavigationState() {
        stateObservations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                self?.navigationStateDidChange()
            },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in
                self?.navigationStateDidChange()
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                self?.navigationStateDidChange()
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                self?.navigationStateDidChange()
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                self?.navigationStateDidChange()
            },
        ]
    }

    /// WebKit KVO notifications are delivered on the thread that changes the
    /// observed UI property. WebKit mutations and this session are main-thread
    /// owned; check that invariant before entering the main actor synchronously.
    nonisolated private func navigationStateDidChange() {
        guard Thread.isMainThread else {
            assertionFailure("WKWebView navigation state changed off the main thread")
            return
        }
        MainActor.assumeIsolated {
            scheduleNavigationStateUpdate()
        }
    }

    private func scheduleNavigationStateUpdate() {
        guard stateUpdateTask == nil else { return }
        stateUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.stateUpdateTask = nil
            let state = BrowserNavigationState(url: self.webView.url,
                                               title: self.webView.title,
                                               isLoading: self.webView.isLoading,
                                               canGoBack: self.webView.canGoBack,
                                               canGoForward: self.webView.canGoForward)
            self.store?.sessionDidObserve(self, state: state)
        }
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        store?.sessionDidStart(tabID: tabID, url: webView.url)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        store?.sessionDidCommit(tabID: tabID, url: webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        store?.sessionDidFinish(tabID: tabID,
                                url: webView.url,
                                title: webView.title,
                                canGoBack: webView.canGoBack,
                                canGoForward: webView.canGoForward)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        store?.sessionDidFail(tabID: tabID, error: error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        store?.sessionDidFail(tabID: tabID, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        store?.sessionDidTerminate(tabID: tabID)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            store?.sessionDidRequestNewTab(url: url)
        }
        return nil
    }
}
