import SwiftUI

/// Whether the About popover is shown.
final class AboutPresentation: ObservableObject {
    @Published var isShown = false
}

/// Explains where the numbers come from. Shown in a popover from the info button in the dropdown footer.
struct AboutView: View {
    static let repositoryURL = URL(string: "https://github.com/evadnoob/tokenstatsbar")!

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TokenStatsBar").font(.headline)
                Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            item("Where the numbers come from",
                 "pi writes a session log for every conversation in ~/.pi/agent/sessions. "
                 + "Each response from a model records its token counts and a cost.")
            item("How cost is calculated",
                 "pi calculates the cost when the response arrives, using its own price list for the model. "
                 + "It is an estimate. Your provider's bill is the source of truth.")
            item("What is counted",
                 "Only requests made through pi. Usage from other tools, websites or subscriptions is not included.")
            item("Privacy",
                 "Only the token counts, cost, model, provider and time are read. Message content is never read, "
                 + "stored or shown. Nothing is sent over the network, and no account or API key is needed.")
            item("Updates",
                 "New log lines are read as they are written. Days use your local time zone. "
                 + "The last 31 days are kept in memory.")
            Divider()
            Link("github.com/evadnoob/tokenstatsbar", destination: AboutView.repositoryURL).font(.caption)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func item(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
