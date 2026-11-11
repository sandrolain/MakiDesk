import AppKit
import Foundation
import WebKit

/// Owns one `WKWebView` and forwards its events to the store. The store keeps
/// the session alive; the session never owns the model.
@MainActor
final class BrowserTabSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let tabID: UUID
    let webView: WKWebView
    private weak var store: BrowserStore?

    init(tabID: UUID, configuration: WKWebViewConfiguration, store: BrowserStore) {
        self.tabID = tabID
        self.store = store
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func stop() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
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
        store?.sessionDidFail(tabID: tabID, message: error.localizedDescription)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        store?.sessionDidFail(tabID: tabID, message: error.localizedDescription)
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
