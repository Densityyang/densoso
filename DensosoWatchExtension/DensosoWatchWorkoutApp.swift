import SwiftUI

@main
struct DensosoWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchCompanionPlaceholder()
        }
    }
}

private struct WatchCompanionPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.text.square")
                .font(.title2)
            Text("densoso")
                .font(.headline)
            Text("Watch 伴侣功能将在后续阶段接入。")
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
