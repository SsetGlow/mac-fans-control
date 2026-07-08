import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = FanControlStore()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        configureMainMenu()
        configureStatusItem()
        configureWorkspaceObservers()
        guard ensureHelperReadyAtLaunch() else {
            NSApplication.shared.terminate(nil)
            return
        }
        store.start()
        showWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        store.restoreAutomaticControl()
    }

    @objc private func showWindow() {
        if window == nil {
            let content = ControlView(store: store)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Mac Fan Control"
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: content)
            self.window = window
        }

        store.setWindowVisible(true)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        store.setWindowVisible(false)
    }

    @objc private func refresh() {
        store.refresh()
    }

    @objc private func toggleStrategy() {
        store.strategyEnabled.toggle()
    }

    @objc private func restoreAutomatic() {
        store.restoreAutomaticControl()
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "Mac Fan Control")
            button.imagePosition = .imageOnly
            button.toolTip = "Mac Fan Control"
            button.target = self
            button.action = #selector(showWindow)
        }

        statusItem = item
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Mac Fan Control")
        let quitItem = NSMenuItem(title: "退出 Mac Fan Control", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        let closeItem = NSMenuItem(title: "关闭窗口", action: #selector(closeWindow), keyEquivalent: "w")
        closeItem.target = self
        windowMenu.addItem(closeItem)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    private func configureWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.store.suspendForSystemSleep() }
        })

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.store.resumeAfterSystemWake() }
        })

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.store.setScreenAwake(false) }
        })

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.store.setScreenAwake(true) }
        })

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.store.setSessionActive(false) }
        })

        workspaceObservers.append(notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.store.setSessionActive(true) }
        })
    }

    private func ensureHelperReadyAtLaunch() -> Bool {
        if FanControlHelperClient.shared.isEnabled {
            return true
        }

        do {
            let state = try FanControlHelperClient.shared.register()
            if state == .enabled {
                return true
            }
            FanControlHelperClient.shared.openLoginItems()
            showPermissionAlert(message: "\(state.title)。请在系统设置的登录项中允许 Mac Fan Control 后重新打开。")
            return false
        } catch {
            FanControlHelperClient.shared.openLoginItems()
            showPermissionAlert(message: "\(error.localizedDescription)\n请在系统设置的登录项中允许 Mac Fan Control 后重新打开。")
            return false
        }
    }

    private func showPermissionAlert(message: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要风扇控制权限"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
