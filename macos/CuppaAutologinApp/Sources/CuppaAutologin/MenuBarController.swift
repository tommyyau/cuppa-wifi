import AppKit
import Combine
import OSLog
import SwiftUI

@MainActor
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    let model = StatusModel()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.bootstrap()
        menuBar = MenuBarController(model: model)
        // The first Spotlight/Finder launch does not send a reopen event.
        // Present after AppKit has finished processing the launch event, just
        // as applicationShouldHandleReopen does on subsequent launches.
        DispatchQueue.main.async { [weak self] in
            self?.menuBar?.showStatus()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        menuBar?.showStatus()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }
}

/// Own the status button and popup together so clicking the cup has an
/// explicit action, independently of SwiftUI's menu-scene visibility state.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var stateSubscription: AnyCancellable?
    private var steamTask: Task<Void, Never>?
    private var motionObserver: NSObjectProtocol?
    private var isConnected = false
    private var alternateSteamFrame = false
    private let logger = Logger(
        subsystem: "io.github.tommyyau.wifi-autologin",
        category: "menu-bar"
    )

    init(model: StatusModel) {
        statusItem = NSStatusBar.system.statusItem(withLength: 32)
        super.init()
        statusItem.autosaveName = "WiFiAutoLogin-status"

        let content = NSHostingController(rootView: PopoverRootView(model: model))
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        popover.contentSize = NSSize(width: 406, height: 520)
        popover.behavior = .transient
        popover.animates = false

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(toggleStatus(_:))
        button.toolTip = "Cuppa Wi-Fi"

        stateSubscription = model.$state.sink { [weak self, weak button] state in
            guard let self else { return }
            let connected = state.lastResult == "ONLINE"
            let changed = self.isConnected != connected
            self.isConnected = connected
            button?.setAccessibilityLabel(
                connected
                    ? "Cuppa Wi-Fi, connected"
                    : "Cuppa Wi-Fi, not connected"
            )
            if changed || button?.image == nil {
                self.updateIconAnimation()
            }
        }
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateIconAnimation() }
        }
        statusItem.isVisible = true
        reportAnchor()
    }

    private func updateIconAnimation() {
        steamTask?.cancel()
        steamTask = nil
        alternateSteamFrame = false
        drawIcon()
        guard isConnected, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        steamTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(550)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                self.alternateSteamFrame.toggle()
                self.drawIcon()
            }
        }
    }

    private func drawIcon() {
        statusItem.button?.image = CafeWiFiIcon.menuBarImage(
            isConnected: isConnected,
            alternateSteamFrame: alternateSteamFrame,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    @objc private func toggleStatus(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showStatus()
        }
    }

    func showStatus() {
        reportAnchor()
        guard let button = statusItem.button, button.window != nil else {
            logger.error("Status button has no presentation anchor")
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
        logger.info("Status popup presented")
    }

    private func reportAnchor() {
        let frame = statusItem.button?.window?.frame ?? .zero
        let hasImage = statusItem.button?.image != nil
        logger.info("Menu-bar anchor: visible=\(self.statusItem.isVisible), image=\(hasImage), frame=\(NSStringFromRect(frame), privacy: .public)")
    }
}
