import AppKit
import ScoutCore
import SwiftUI

/// The main window; it can always become key and main.
final class ScoutWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// SwiftUI's stock NSHostingView may consume the first click solely to activate an app.
/// Routine Scout is frequently opened from another app, so its controls must accept that click.
final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Native AppKit lifecycle and status item. Using NSStatusItem here avoids the SwiftUI
/// MenuBarExtra/view-bridge failure seen on macOS 26, where the item and window were drawn
/// but pointer events never reached their controls.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var model: AppModel?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installStatusItem()
        NSApp.activate(ignoringOtherApps:true)
        // Windows and event monitors must only be created once AppKit has finished launching.
        AppDelegate.model?.launch()
    }

    /// Right-clicking the Dock icon offers the same commands as the menu-bar item. On notched
    /// MacBooks a crowded menu bar can hide status items, so the Dock is the reliable fallback.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title:"Routine Scout")
        rebuild(menu)
        return menu
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName:"sparkle.magnifyingglass",accessibilityDescription:"Routine Scout")
        item.button?.toolTip = "Routine Scout"
        let menu = NSMenu(title:"Routine Scout")
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuild(menu)
    }

    func menuWillOpen(_ menu: NSMenu) { rebuild(menu) }

    private func add(_ title: String,_ action: Selector,to menu: NSMenu,key: String = "") {
        let item = NSMenuItem(title:title,action:action,keyEquivalent:key)
        item.target = self
        menu.addItem(item)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title:AppDelegate.model?.status ?? "Routine Scout",action:nil,keyEquivalent:"")
        status.isEnabled = false
        menu.addItem(status)
        add("Open Routine Scout",#selector(openHome),to:menu)
        add("Activity",#selector(openActivity),to:menu)
        menu.addItem(.separator())

        let replay = NSMenuItem(title:"Replay an example",action:nil,keyEquivalent:"")
        let submenu = NSMenu(title:"Replay an example")
        for shape in Fixtures.shapes {
            let item = NSMenuItem(title:Fixtures.title(shape),action:#selector(replayExample(_:)),keyEquivalent:"")
            item.target = self
            item.representedObject = shape
            submenu.addItem(item)
        }
        replay.submenu = submenu
        menu.addItem(replay)
        menu.addItem(.separator())

        if AppDelegate.model?.policy.paused == true {
            add("Resume",#selector(resume),to:menu)
        } else {
            add("Pause for 1 hour",#selector(pause),to:menu)
        }
        add("Preferences…",#selector(openPreferences),to:menu)
        menu.addItem(.separator())
        add("Quit Routine Scout",#selector(quit),to:menu,key:"q")
    }

    @objc private func openHome() { AppDelegate.model?.show("home") }
    @objc private func openActivity() { AppDelegate.model?.show("activity") }
    @objc private func openPreferences() { AppDelegate.model?.show("preferences") }
    @objc private func replayExample(_ sender: NSMenuItem) {
        guard let shape = sender.representedObject as? String else { return }
        AppDelegate.model?.demo(shape)
    }
    @objc private func pause() { AppDelegate.model?.pause(3600) }
    @objc private func resume() { AppDelegate.model?.pause(0) }
    @objc private func quit() { AppDelegate.model?.stop(); NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool {
        AppDelegate.model?.show()
        return true
    }
}
