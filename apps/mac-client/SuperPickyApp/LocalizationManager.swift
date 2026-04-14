import Foundation
import AppKit

enum LocalizationManager {
    private static var menuKeys: [ObjectIdentifier: String] = [:]

    /// Look up a localized string for a given language.
    static func string(_ key: String, language: AppLanguage) -> String {
        guard let bundle = bundle(for: language) else { return key }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// Localize macOS menu bar titles at runtime.
    static func localizeMenuBar(language: AppLanguage) {
        guard let bundle = bundle(for: language),
              let mainMenu = NSApp.mainMenu else { return }
        localizeMenu(mainMenu, bundle: bundle)
    }

    private static func bundle(for language: AppLanguage) -> Bundle? {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    private static func localizeMenu(_ menu: NSMenu, bundle: Bundle) {
        let menuID = ObjectIdentifier(menu)
        if menuKeys[menuID] == nil { menuKeys[menuID] = menu.title }
        if let key = menuKeys[menuID] {
            menu.title = bundle.localizedString(forKey: key, value: nil, table: nil)
        }

        for item in menu.items where !item.isSeparatorItem {
            let itemID = ObjectIdentifier(item)
            if menuKeys[itemID] == nil { menuKeys[itemID] = item.title }
            if let key = menuKeys[itemID] {
                item.title = bundle.localizedString(forKey: key, value: nil, table: nil)
            }
            if let submenu = item.submenu {
                localizeMenu(submenu, bundle: bundle)
            }
        }
    }
}
