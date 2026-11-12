import AppKit
import Foundation
import WebKit

/// Owns one `WKWebView` and forwards its events to the store. The store keeps
/// the session alive; the session never owns the model.
@MainActor
final class BrowserTabSession: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private(set) var tabID: UUID
    private(set) var webView: WKWebView!
    private weak var store: BrowserStore?

    private static let passwordFocusScript = #"""
    (function() {
        const observer = new MutationObserver(() => {
            document.querySelectorAll('input[type="password"], input[autocomplete="current-password"], input[autocomplete="username"]').forEach(el => {
                el.addEventListener('focus', () => {
                    window.webkit.messageHandlers.passwordFocused.postMessage(el.id || 'password-field');
                });
            });
        });
        observer.observe(document.body, { childList: true, subtree: true });
        document.querySelectorAll('input[type="password"], input[autocomplete="current-password"], input[autocomplete="username"]').forEach(el => {
            el.addEventListener('focus', () => {
                window.webkit.messageHandlers.passwordFocused.postMessage(el.id || 'password-field');
            });
        });
    })();
    """#

    init(tabID: UUID, configuration: WKWebViewConfiguration, store: BrowserStore) {
        self.tabID = tabID
        self.store = store
        super.init()
        configuration.userContentController.add(self, name: "passwordFocused")
        let userScript = WKUserScript(
            source: BrowserTabSession.passwordFocusScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(userScript)
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        if message.name == "passwordFocused" {
            store?.passwordFieldFocused(tabID: tabID)
        }
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
