import AppKit
import SwiftUI

@main
struct DecibelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ControlPanel()
                .environment(appDelegate.controller)
                .environment(appDelegate.controller.meters)
                .environment(appDelegate.controller.nowPlaying)
        } label: {
            MenuBarIcon(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AudioController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // Screenshot hook: `-appearance light` / `-appearance dark`.
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        #endif
        controller.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown() // Remove the tap so apps are unmuted immediately.
    }
}

private struct MenuBarIcon: View {
    let controller: AudioController

    var body: some View {
        Group {
            switch controller.status {
            case .needsPermission, .failed:
                Image(systemName: "speaker.badge.exclamationmark")
            default:
                Image(systemName: VolumeSymbol.name(volume: controller.outputVolume, muted: controller.outputMuted))
            }
        }
        .accessibilityLabel("Decibel")
    }
}
