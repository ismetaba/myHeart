import SwiftUI
import UIKit

// MARK: - Layout

extension View {
    /// Standard card chrome used by every top-level card in the app.
    func cardBackground(cornerRadius: CGFloat = 16) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    /// Keeps scrolling content at a readable width on iPad while the scroll
    /// view (and its background / pull-to-refresh) still spans the screen.
    /// Apply it to the content inside a ScrollView, not to the ScrollView.
    func readableContentWidth(_ maxWidth: CGFloat = 720) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}

// MARK: - Banners & empty states

/// Inline, dismissible message (errors, warnings, hints). Text uses the
/// primary color for contrast; only the icon carries the tint.
/// Optional single action button (e.g. "Open Settings") and dismiss button.
struct InlineBanner: View {
    let message: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.callout.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(tint)
                }
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -12)
                .padding(.trailing, -10)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }
}

/// iOS 16 stand-in for `ContentUnavailableView` (iOS 17+).
struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = { EmptyView() }
    }
}

// MARK: - Zone chip

/// The one zone badge used everywhere. Fill uses the zone color, text and
/// icon use `zone.textColor` so they stay readable in Light Mode.
struct ZoneChip: View {
    enum Size { case small, regular, large }

    let zone: HeartRateZone
    var size: Size = .regular

    var body: some View {
        HStack(spacing: size == .small ? 4 : 6) {
            Image(systemName: zone.systemImage)
                .font(iconFont)
            // Full names everywhere: the short forms ("Card", "Fat") read as words.
            Text(zone.label)
                .font(textFont)
        }
        .padding(.horizontal, size == .small ? 8 : (size == .large ? 14 : 10))
        .padding(.vertical, size == .small ? 3 : (size == .large ? 6 : 5))
        .background(Capsule().fill(zone.color.opacity(0.18)))
        .foregroundStyle(zone.textColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(zone.label) zone")
    }

    private var iconFont: Font {
        switch size {
        case .small: return .caption2.weight(.semibold)
        case .regular: return .caption2.weight(.semibold)
        case .large: return .caption.weight(.semibold)
        }
    }

    private var textFont: Font {
        switch size {
        case .small: return .caption2.weight(.medium)
        case .regular: return .caption.weight(.semibold)
        case .large: return .callout.weight(.semibold)
        }
    }
}

// MARK: - Haptics

/// One vocabulary for feedback: `selection` for pickers / presets,
/// `success` / `error` only after an action has actually finished,
/// `warning` when something needs attention (e.g. an emergency appears).
enum Haptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
