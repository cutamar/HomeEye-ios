import SwiftUI
import UIKit
import HomeEyeCore

struct JoystickView: View {
    let size: CGFloat
    let knob: CGFloat
    let translucent: Bool
    let onMove: (Double, Double) -> Void
    let onRelease: () -> Void

    @State private var knobOffset: CGSize = .zero
    @State private var isDragging = false

    init(
        size: CGFloat = 168,
        knob: CGFloat = 64,
        translucent: Bool = false,
        onMove: @escaping (Double, Double) -> Void,
        onRelease: @escaping () -> Void
    ) {
        self.size = size
        self.knob = knob
        self.translucent = translucent
        self.onMove = onMove
        self.onRelease = onRelease
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(translucent ? 0.10 : 0.06))
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)

            ForEach([0.0, 90.0, 180.0, 270.0], id: \.self) { angle in
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .offset(y: -(size / 2 - 18))
                    .rotationEffect(.degrees(angle))
            }

            Circle()
                .fill(Color.accentColor.opacity(translucent ? 0.85 : 1))
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 3))
                .frame(width: knob, height: knob)
                .offset(knobOffset)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    let r = JoystickMath.normalize(
                        dx: Double(value.location.x - size / 2),
                        dy: Double(value.location.y - size / 2),
                        radius: Double((size - knob) / 2)
                    )
                    knobOffset = CGSize(width: r.knobX, height: r.knobY)
                    onMove(r.x, r.y)
                }
                .onEnded { _ in
                    isDragging = false
                    onRelease()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        knobOffset = .zero
                    }
                }
        )
        .accessibilityLabel("Pan and tilt control")
        .accessibilityHint("Drag to move the camera")
    }
}
