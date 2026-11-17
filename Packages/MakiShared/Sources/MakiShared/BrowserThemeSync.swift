import Foundation

public enum BrowserThemeSync {
    public static let fileName = "browser-theme.json"
    public static let didChangeNotification =
        Notification.Name("com.makidesk.browser.themeChanged")
}
