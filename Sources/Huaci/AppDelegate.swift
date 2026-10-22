import AppKit
import Combine
import HuaciCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var subscriptions: Set<AnyCancellable> = []

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

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()

        // The icon gets a dot while something needs attention.
        model.objectWillChange.merge(with: model.settings.objectWillChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &subscriptions)
        Timer.publish(every: 5, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.model.refreshAccessibility() }
            .store(in: &subscriptions)
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button,
              let symbol = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "划词")
        else { return }
        guard !model.attentionItems.isEmpty else {
            symbol.isTemplate = true
            button.image = symbol
            return
        }
        // Template images cannot carry a colored dot, so draw one tinted for
        // the menu bar's current appearance.
        let size = symbol.size
        let image = NSImage(size: size)
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            symbol.draw(in: CGRect(origin: .zero, size: size))
            NSColor.labelColor.set()
            CGRect(origin: .zero, size: size).fill(using: .sourceAtop)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: CGRect(x: size.width - 6, y: size.height - 6, width: 6, height: 6)).fill()
            image.unlockFocus()
        }
        image.accessibilityDescription = "划词（需要处理）"
        button.image = image
    }

    /// Rebuilt on open so the shortcut and status are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshAccessibility()
        menu.removeAllItems()

        let header = NSMenuItem()
        let headerView = NSHostingView(rootView: MenuHeaderView(
            serviceLine: model.serviceLine,
            items: model.attentionItems,
            perform: { [weak self] item in
                self?.statusItem.menu?.cancelTracking()
                item.perform()
            }
        ))
        headerView.frame = CGRect(origin: .zero, size: headerView.fittingSize)
        header.view = headerView
        menu.addItem(header)
        menu.addItem(.separator())

        let translate = item("翻译选中文字", #selector(translate))
        setKeyEquivalent(of: translate, to: model.settings.shortcut)
        translate.isEnabled = model.accessibilityTrusted
        menu.addItem(translate)
        menu.addItem(item("打开划词", #selector(showMain), key: "o"))
        menu.addItem(.separator())

        let services = NSMenu()
        for service in TranslationService.allCases {
            var title = service.shortName
            if !model.isConfigured(service) { title += service.usesOAuth ? "（未登录）" : "（未配置）" }
            let entry = item(title, #selector(selectService(_:)))
            entry.representedObject = service.rawValue
            entry.state = model.settings.activeService == service ? .on : .off
            services.addItem(entry)
        }
        services.addItem(.separator())
        services.addItem(item("管理服务…", #selector(showServiceSettings)))
        let servicesItem = NSMenuItem(title: "翻译服务", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("设置…", #selector(showSettings), key: ","))
        menu.addItem(item("退出划词", #selector(quit), key: "q"))
    }

    /// Shows the global shortcut next to the item, e.g. ⌃⌥T.
    private func setKeyEquivalent(of item: NSMenuItem, to shortcut: Shortcut) {
        guard let name = Shortcut.keyNames[shortcut.keyCode], name.count == 1 else {
            item.title += "（\(shortcut.displayString)）"
            return
        }
        var flags: NSEvent.ModifierFlags = []
        if shortcut.modifiers.contains(.control) { flags.insert(.control) }
        if shortcut.modifiers.contains(.option) { flags.insert(.option) }
        if shortcut.modifiers.contains(.shift) { flags.insert(.shift) }
        if shortcut.modifiers.contains(.command) { flags.insert(.command) }
        item.keyEquivalent = name.lowercased()
        item.keyEquivalentModifierMask = flags
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Main menu

    /// App, Edit and View menus while one of the app's windows is active.
    private func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("关于划词", #selector(showAbout)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("设置…", #selector(showSettings), key: ","))
        appMenu.addItem(.separator())
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

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "显示")
        for section in MainSection.allCases {
            let entry = item(section.title, #selector(showSection(_:)), key: section.keyEquivalent)
            entry.representedObject = section.rawValue
            viewMenu.addItem(entry)
        }
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        NSApp.mainMenu = main
    }

    // MARK: Actions

    @objc private func translate() { model.triggerTranslation() }
    /// Switches the service; an unconfigured one opens its settings.
    @objc private func selectService(_ sender: NSMenuItem) {
        guard let service = (sender.representedObject as? String).flatMap(TranslationService.init(rawValue:)) else { return }
        model.settings.activeService = service
        if !model.isConfigured(service) { WindowRouter.shared.showSettings(.service) }
    }
    @objc private func showMain() { WindowRouter.shared.showMain() }
    @objc private func showSection(_ sender: NSMenuItem) {
        WindowRouter.shared.showMain((sender.representedObject as? String).flatMap(MainSection.init(rawValue:)))
    }
    @objc private func showSettings() { WindowRouter.shared.showSettings() }
    @objc private func showServiceSettings() { WindowRouter.shared.showSettings(.service) }
    @objc private func showAbout() { WindowRouter.shared.showSettings(.about) }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Top of the menu bar menu: app, active service, and the first problem to fix.
private struct MenuHeaderView: View {
    let serviceLine: String
    let items: [AttentionItem]
    let perform: (AttentionItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("划词").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle().fill(items.isEmpty ? Theme.successDot : Theme.warningDot).frame(width: 6, height: 6)
                        Text(items.isEmpty ? serviceLine : "需要处理 \(items.count) 项")
                            .foregroundStyle(items.isEmpty ? .secondary : Theme.warning)
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 14)
            if let item = items.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 12, weight: .semibold))
                    Text(item.message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Button(item.actionTitle) { perform(item) }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 2)
                }
                .foregroundStyle(Theme.warning)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warningSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 10)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(width: 280, alignment: .leading)
    }
}
