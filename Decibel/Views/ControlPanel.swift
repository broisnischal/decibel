import AppKit
import DecibelKit
import SwiftUI

/// The menu-bar panel: a main page (like the macOS Sound menu) that drills into detail pages.
struct ControlPanel: View {
    @Environment(AudioController.self) private var controller

    var body: some View {
        ZStack(alignment: .top) {
            switch controller.page {
            case .main:
                MainPage().transition(.push(from: .leading))
            case .equalizer:
                EqualizerPage().transition(.push(from: .trailing))
            case .effects:
                EffectsPage().transition(.push(from: .trailing))
            case .microphone:
                MicrophonePage().transition(.push(from: .trailing))
            case .devices:
                DevicesPage().transition(.push(from: .trailing))
            }
        }
        .padding(.bottom, 6)
        .frame(width: Metrics.panelWidth)
        .clipped()
        .animation(.snappy(duration: 0.28), value: controller.page)
        .background(WindowVisibilityReader { controller.panelVisible = $0 })
    }
}

struct StatusBanner: View {
    let message: String
    let actionTitle: String
    let action: (AudioController) -> Void

    init?(status: AudioController.Status) {
        switch status {
        case .needsPermission:
            message = "Decibel needs System Audio Recording access to process sound."
            actionTitle = "Open Settings…"
            action = { $0.openPermissionSettings() }
        case .failed(let error):
            message = error
            actionTitle = "Try Again"
            action = { $0.retry() }
        default:
            return nil
        }
    }

    @Environment(AudioController.self) private var controller

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
            .font(.system(size: 12))
            Button(actionTitle) { action(controller) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
        .padding(.horizontal, Metrics.inset)
        .padding(.bottom, 6)
    }
}

/// Reports whether the hosting window is on screen, so meters and the mixer only poll while visible.
private struct WindowVisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Tracker(onChange: onChange) }
    func updateNSView(_ view: NSView, context: Context) { (view as? Tracker)?.onChange = onChange }

    /// Menu-bar panels are hidden with orderOut, which posts no occlusion change, so key status is the reliable
    /// signal: the panel takes key when it opens and resigns it when it closes.
    final class Tracker: NSView {
        var onChange: (Bool) -> Void
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return onChange(false) }
            let events: [(Notification.Name, Bool?)] = [
                (NSWindow.didBecomeKeyNotification, true),
                (NSWindow.didResignKeyNotification, false),
                (NSWindow.willCloseNotification, false),
                (NSWindow.didChangeOcclusionStateNotification, nil),
            ]
            observers = events.map { name, visible in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.onChange(visible ?? (self.window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false))
                    }
                }
            }
            onChange(window.isKeyWindow || (window.isVisible && window.occlusionState.contains(.visible)))
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
