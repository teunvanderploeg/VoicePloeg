import PloegKit
import SwiftUI

/// Presentation of the canonical coordinator state. No recording state is stored here.
@MainActor
enum VoiceInterface {
    static func title(for coordinator: AppCoordinator) -> String {
        switch coordinator.state {
        case .idle:
            return isReady(coordinator) ? UserFacingMessage.readyStatus : UserFacingMessage.setupStatus
        case .starting: return UserFacingMessage.startingRecording
        case .listening: return UserFacingMessage.recordingStatus
        case .processing: return UserFacingMessage.processingStatus
        case .error: return UserFacingMessage.attentionStatus
        }
    }

    static func color(for coordinator: AppCoordinator) -> Color {
        switch coordinator.state {
        case .idle: return isReady(coordinator) ? PloegTheme.success : PloegTheme.warning
        case .listening: return PloegTheme.recording
        case .starting, .processing: return PloegTheme.accent
        case .error: return PloegTheme.warning
        }
    }

    static func symbol(for coordinator: AppCoordinator) -> String {
        switch coordinator.state {
        case .idle: return isReady(coordinator) ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .starting, .processing: return "hourglass"
        case .listening: return "record.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private static func isReady(_ coordinator: AppCoordinator) -> Bool {
        coordinator.permissionStatus.microphoneGranted
            && coordinator.permissionStatus.accessibilityGranted
            && coordinator.canUseSelectedBackend()
    }
}

@MainActor
struct VoiceRecordButtonStyle: ButtonStyle {
    let isRecording: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(PloegTheme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                (isRecording ? PloegTheme.recording : PloegTheme.accent)
                    .opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: PloegTheme.controlRadius)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: PloegTheme.controlRadius))
    }
}
