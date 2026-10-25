import AppKit
import SwiftUI

struct HotkeyRecorderView: View {
    @Binding var hotkey: HotkeyCombination
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text("Current: \(hotkey.displayText)")
            Spacer()
            Button(isRecording ? "Press keys..." : "Record Hotkey") {
                toggleRecording()
            }
        }
        .onDisappear {
            stopMonitoring()
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    private func startMonitoring() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopMonitoring()
                return nil
            }
            let combo = HotkeyCombination.from(event: event)
            guard combo.isValidRecordingShortcut else {
                return nil
            }

            hotkey = combo
            stopMonitoring()
            return nil
        }
    }

    private func stopMonitoring() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
