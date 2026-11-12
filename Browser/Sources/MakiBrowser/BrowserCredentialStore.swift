import Foundation
import Security
import WebKit

struct BrowserCredential: Identifiable, Equatable {
    var domain: String
    var username: String
    var password: String

    var id: String { "\(domain)|\(username)" }
}

/// Credentials live in the login Keychain as Internet Password items. This is
/// the system Keychain, not Safari's private password database: an app can
/// create and read its own items, while Safari's saved passwords stay outside
/// the app's access control. The UI says "Passwords (Keychain)" accordingly.
struct BrowserCredentialStore {
    private static let serviceLabel = "MakiDesk Browser"

    func credentials(for domain: String) -> [BrowserCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecAttrDescription as String: Self.serviceLabel,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8) else { return nil }
            return BrowserCredential(domain: domain, username: account, password: password)
        }
        .sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
    }

    @discardableResult
    func save(domain: String, username: String, password: String) -> Bool {
        delete(domain: domain, username: username)
        let item: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecAttrAccount as String: username,
            kSecAttrDescription as String: Self.serviceLabel,
            kSecAttrLabel as String: "\(Self.serviceLabel) — \(domain)",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeHTMLForm,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecValueData as String: Data(password.utf8),
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ credential: BrowserCredential) {
        delete(domain: credential.domain, username: credential.username)
    }

    private func delete(domain: String, username: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: domain,
            kSecAttrAccount as String: username,
            kSecAttrDescription as String: Self.serviceLabel,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Fills the first username/password pair on the page. The native value
    /// setter is used so React/SPA listeners see the change.
    static func fill(_ credential: BrowserCredential, in webView: WKWebView) async -> Bool {
        guard let payload = try? JSONSerialization.data(withJSONObject: [credential.username, credential.password]),
              let json = String(data: payload, encoding: .utf8) else { return false }

        let script = #"""
        (() => {
          const [username, password] = \#(json);
          const setValue = (element, value) => {
            const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')?.set;
            if (setter) setter.call(element, value); else element.value = value;
            element.dispatchEvent(new Event('input', { bubbles: true }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
          };
          const user = document.querySelector(
            'input[autocomplete="username"], input[type="email"], input[name*="user" i], input[id*="user" i]'
          );
          const pass = document.querySelector('input[type="password"]');
          if (!pass) return false;
          if (user) setValue(user, username);
          setValue(pass, password);
          pass.focus();
          return true;
        })()
        """#
        let value = try? await webView.evaluateJavaScript(script)
        return (value as? Bool) ?? false
    }
}
