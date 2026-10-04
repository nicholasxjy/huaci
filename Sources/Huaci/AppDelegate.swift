import AppKit
import Combine
import HuaciCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        WindowRouter.shared.model = model
        setUpMainMenu()
        setUpStatusItem()

        HotKeyCenter.shared.onPress = { [weak self] in self?.model.triggerTranslation() }
        model.registerSavedShortcut()

        if !model.settings.onboardingCompleted {
            WindowRouter.shared.showOnboarding()
        }
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "划词")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt on open so the shortcut and permission state are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshAccessibility()
        menu.removeAllItems()

        menu.addItem(item("翻译选中文字（\(model.settings.shortcut.displayString)）", #selector(translate)))
        if let error = model.hotKeyError {
            let warning = NSMenuItem(title: "⚠︎ \(error)", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        if !model.accessibilityTrusted {
            menu.addItem(item("开启辅助功能权限…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())
        menu.addItem(item("查询历史…", #selector(showHistory)))
        menu.addItem(item("生词本…", #selector(showVocabulary)))
        menu.addItem(item("设置…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("退出划词", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// Edit menu so ⌘C/⌘V/⌘A work in text fields of the app's windows.
    private func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出划词", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc private func translate() { model.triggerTranslation() }
    @objc private func showHistory() { WindowRouter.shared.showHistory() }
    @objc private func showVocabulary() { WindowRouter.shared.showVocabulary() }
    @objc private func showSettings() { WindowRouter.shared.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openAccessibility() {
        SystemSelectionEnvironment.requestAccessibilityPrompt()
        SystemSelectionEnvironment.openAccessibilitySettings()
    }
}
