import SwiftUI
import AppKit

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
            Divider()
            Text(vm.statusMessage)
            Divider()
            Button("종료") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: vm.isRecording ? "waveform.circle.fill" : "waveform")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only — no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        showPanel()
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
