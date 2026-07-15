import SwiftUI
import AppKit

extension Notification.Name {
    static let openWhisperNotionSettings = Notification.Name("openWhisperNotionSettings")
    static let openWhisperNotionPagePicker = Notification.Name("openWhisperNotionPagePicker")
}

/// WhisperNotion menu-bar app. The menu-bar item is the launcher/status; the
/// live transcript lives in a non-activating floating panel that survives focus
/// loss (autoplan decision: a popover dismisses when you click back into your
/// meeting, so it can't host the live experience).
@main
struct WhisperNotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var vm = RecorderViewModel.shared

    var body: some Scene {
        MenuBarExtra {
            Button(vm.isRecording ? "정지" : "녹음 시작") { vm.toggle() }
                .keyboardShortcut("r")
            Button("자막 창 열기") { appDelegate.showPanel() }
            Button("설정…") { appDelegate.showSettings() }
                .keyboardShortcut(",")
            Divider()
            Text(vm.statusMessage)
            if !vm.notionSync.isEmpty { Text(vm.notionSync) }
            Divider()
            Button("종료") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: vm.isRecording ? "waveform.circle.fill" : "waveform")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var pagePickerWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only — no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        // The panel's gear button routes here (the menu-bar icon can be hidden
        // behind the notch on full menu bars, so we don't depend on it).
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettingsFromNotification),
            name: .openWhisperNotionSettings, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(openPagePickerFromNotification),
            name: .openWhisperNotionPagePicker, object: nil)
        showPanel()
    }

    @objc private func openSettingsFromNotification() {
        showSettings()
    }

    @objc private func openPagePickerFromNotification() {
        showPagePicker()
    }

    func showPagePicker() {
        if let pagePickerWindow {
            NSApp.activate(ignoringOtherApps: true)
            pagePickerWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = PagePickerView(
            onPick: { [weak self] ref in
                self?.pagePickerWindow?.close()
                self?.pagePickerWindow = nil
                RecorderViewModel.shared.startWithChosenPage(id: ref.id, title: ref.title)
            },
            onRecordLocal: { [weak self] in
                self?.pagePickerWindow?.close()
                self?.pagePickerWindow = nil
                RecorderViewModel.shared.startLocalOnly()
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Notion 페이지 선택"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.level = .floating
        // Top-center of the active screen.
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2,
                                          y: vf.maxY - size.height - 8))
        } else {
            window.center()
        }
        pagePickerWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Show a normal settings window. An accessory (menu-bar) app must activate
    /// itself, or the window opens behind everything and looks "missing".
    func showSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingView(rootView: SettingsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "WhisperNotion 설정"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Show (or focus) the floating transcript panel.
    @MainActor
    func showPanel() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let hosting = NSHostingView(rootView: LiveTranscriptView())
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.title = "WhisperNotion"
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = hosting
        p.center()
        p.orderFrontRegardless()
        panel = p
    }
}
