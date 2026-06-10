import SwiftUI

/// A centered, unintrusive placeholder shown in a detail pane when there is no
/// live data to render — typically because the core is stopped. Uses a large
/// muted SF Symbol over a short Chinese explanation, the native "content
/// unavailable" idiom without nesting boxes.
struct DashboardEmptyState: View {
    let symbolName: String
    let title: String
    var message: String?

    init(symbolName: String, title: String, message: String? = nil) {
        self.symbolName = symbolName
        self.title = title
        self.message = message
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbolName)
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(Theme.Color.tertiaryLabel)
            Text(title)
                .font(Theme.Font.heading)
                .foregroundStyle(Theme.Color.secondaryLabel)
            if let message {
                Text(message)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.tertiaryLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
    }
}
