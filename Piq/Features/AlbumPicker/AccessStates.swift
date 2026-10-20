import SwiftUI

/// The picker's page when there is no grid to show: the intro at the top and `message` in the
/// space below it, a little above the middle. It scrolls instead when the message doesn't fit
/// (large text, short windows).
struct PickerMessagePage<Message: View>: View {
    let layout: PickerLayout
    @ViewBuilder let message: Message

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 0) {
                PickerIntro()
                Spacer(minLength: 40)
                centeredMessage
                Spacer(minLength: 40)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, layout.margin)
            .padding(.top, PickerLayout.introTopPadding)

            ScrollView {
                VStack(alignment: .leading, spacing: 40) {
                    PickerIntro()
                    centeredMessage
                }
                .padding(.horizontal, layout.margin)
                .padding(.top, PickerLayout.introTopPadding)
                .padding(.bottom, 40)
            }
        }
    }

    private var centeredMessage: some View {
        message
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
    }
}

/// While the system asks for Photos access (first launch).
struct WaitingForAccessView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(Palette.textMuted)
            Text("Waiting for access to Photos")
                .font(.lead)
                .foregroundStyle(Palette.textMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Access denied or restricted: why Piq needs Photos, and a way to Settings.
struct AccessNeededView: View {
    let access: LibraryAccess

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            MessageIcon(systemImage: access == .restricted ? "lock" : "photo.on.rectangle.angled")
            Text(title)
                .font(.dialogTitle)
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 24)
            Text(message)
                .font(.lead)
                .foregroundStyle(Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Button("Open Settings", action: openSettings)
                .buttonStyle(.pill(.primary, height: Metrics.largeButtonHeight, font: .largeButtonLabel))
                .accessibilityIdentifier(A11yID.Picker.openSettings)
                .padding(.top, 28)
        }
    }

    private var title: String {
        access == .restricted ? "Photos access is restricted" : "Piq needs access to your photos"
    }

    private var message: String {
        if access == .restricted {
            return "Screen Time or device management doesn't allow Piq to use Photos on this iPad. Piq needs it to show the photos of the album you pick so you can sort them."
        }
        return "Piq shows the photos of the album you pick so you can sort them. Nothing leaves Photos until you empty Piq's trash and confirm."
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

/// Limited access: Piq only sees the photos the person picked; they can change the selection.
struct LimitedAccessNotice: View {
    /// Puts the button under the message (narrow windows) instead of beside it.
    let isStacked: Bool

    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if isStacked {
                VStack(alignment: .leading, spacing: 12) {
                    message
                    changeButton
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 16) {
                    message
                    changeButton
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: Metrics.tileCorner, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: Metrics.tileCorner, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
    }

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Palette.textMuted)
                .accessibilityHidden(true)
            Text("Piq can only see the photos you've allowed.")
                .font(.text(15, .medium))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var changeButton: some View {
        Button("Change selection") {
            app.library.presentLimitedLibraryPicker()
        }
        .buttonStyle(.pill(.secondary))
        .fixedSize()
        .accessibilityIdentifier(A11yID.Picker.changeSelection)
    }
}
