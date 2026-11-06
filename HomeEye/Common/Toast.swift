import SwiftUI

struct Toast: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                ZStack {
                    if let message {
                        Text(message)
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: message)
            }
            .task(id: message) {
                guard message != nil else { return }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if !Task.isCancelled {
                    message = nil
                }
            }
    }
}

extension View {
    func toast(_ message: Binding<String?>) -> some View {
        modifier(Toast(message: message))
    }
}
