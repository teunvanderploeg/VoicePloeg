import AppKit
import PloegKit
import SwiftUI

struct HotkeyRecorderView: View {
    @Binding var hotkey: HotkeyCombination
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(hotkey.displayText)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(PloegTheme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(PloegTheme.canvas, in: RoundedRectangle(cornerRadius: PloegTheme.controlRadius))
            Spacer()
            Button(isRecording ? UserFacingMessage.shortcutListening : UserFacingMessage.recordShortcut) {
                toggleRecording()
            }
            .buttonStyle(PloegSecondaryButtonStyle())
            .help(isRecording ? UserFacingMessage.escapeToCancel : UserFacingMessage.dictationHotkeyHelp)
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
