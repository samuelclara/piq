import SwiftUI

/// App-wide toasts ("✓ Marked for deletion"), shown near the top and dismissed after 2.2s.
/// VoiceOver announces each one.
@MainActor
@Observable
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let systemImage: String?
    }

    private(set) var current: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(_ message: String, systemImage: String? = "checkmark", duration: Duration = Metrics.toastDuration) {
        let toast = Toast(message: message, systemImage: systemImage)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            current = toast
        }
        AccessibilityNotification.Announcement(message.spoken).post()
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(toast.id)
        }
    }

    func dismiss(_ id: Toast.ID? = nil) {
        guard let current, id == nil || current.id == id else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            self.current = nil
        }
    }
}

struct ToastView: View {
    let toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage = toast.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
            }
            Text(toast.message)
                .font(.toast)
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 18)
        .frame(minHeight: Metrics.minTouch)
        .background(Capsule().fill(Palette.raised))
        .overlay(Capsule().strokeBorder(Palette.hairlineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        // The message alone: the icon is decoration (a checkmark would read "Selected").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(toast.message.spoken)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier(A11yID.toast)
    }
}

extension View {
    /// Shows `center`'s toasts just below the 76pt top bar.
    func toastOverlay(_ center: ToastCenter) -> some View {
        modifier(ToastOverlay(center: center))
    }

    /// A centered card over a dimmed backdrop (used for the "Delete 22 photos?" confirmation).
    /// Tapping the backdrop dismisses it. While it is up, the screen under it is hidden from
    /// VoiceOver and Full Keyboard Access, so focus stays on the card.
    func modalCard<Card: View>(isPresented: Binding<Bool>, @ViewBuilder card: @escaping () -> Card) -> some View {
        modifier(ModalCard(isPresented: isPresented, card: card))
    }
}

/// Toasts slide down from under the top bar (they only fade with Reduce Motion).
private struct ToastOverlay: ViewModifier {
    let center: ToastCenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            ZStack {
                if let toast = center.current {
                    ToastView(toast: toast)
                        .id(toast.id)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.top, Metrics.topBarHeight + 14)
            .allowsHitTesting(false)
        }
    }
}

/// See `modalCard(isPresented:card:)`.
private struct ModalCard<Card: View>: ViewModifier {
    @Binding var isPresented: Bool
    let card: () -> Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(isPresented)
            .overlay {
                ZStack {
                    if isPresented {
                        Color.black.opacity(0.6)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { isPresented = false }
                            .accessibilityHidden(true)
                            .transition(.opacity)
                        card()
                            .padding(28)
                            .frame(maxWidth: 480)
                            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Palette.panel))
                            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Palette.hairlineStrong, lineWidth: 1))
                            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
                            .padding(24)
                            .accessibilityElement(children: .contain)
                            .accessibilityAddTraits(.isModal)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isPresented)
            }
    }
}
