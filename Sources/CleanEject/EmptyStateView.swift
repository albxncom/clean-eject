import SwiftUI

/// A centered placeholder for an empty detail column: symbol, short title, one line of guidance, optional actions.
/// Deliberately smaller than the system placeholder view, whose large title reads like a pre-26 app in a small window.
struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let description: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3)
                .fontWeight(.medium)
            Text(description)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            actions()
                .padding(.top, 8)
                .foregroundStyle(.primary)
        }
        .foregroundStyle(.secondary)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, description: String) {
        self.init(systemImage: systemImage, title: title, description: description) { EmptyView() }
    }
}
