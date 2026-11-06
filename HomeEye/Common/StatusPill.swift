import SwiftUI
import HomeEyeCore

struct StatusPill: View {
    let status: StreamStatus

    private var color: Color {
        switch status {
        case .live: return .liveGreen
        case .connecting: return Color.white.opacity(0.6)
        case .retrying: return .warnAmber
        }
    }

    private var text: String {
        switch status {
        case .live: return "LIVE"
        case .connecting: return "Connecting…"
        case .retrying(let reason): return "\(reason) · retrying"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}
