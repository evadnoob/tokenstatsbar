import SwiftUI

/// Whether the About popover is shown.
final class AboutPresentation: ObservableObject {
    @Published var isShown = false
}

/// Explains where the numbers come from. Shown in a popover from the info button in the dropdown footer, or from the footer menu.
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
                 + "Claude Code (the claude command line tool) writes transcripts in ~/.claude/projects and "
                 + "~/.config/claude/projects. Each response records its token counts. "
                 + "Claude Code writes several lines per response, and each response is counted once.")
            item("How cost is calculated",
                 "All costs are API-equivalent: what the same usage would cost with an API key. "
                 + "Subscriptions are billed differently. pi records a cost for each response. "
                 + "For Claude Code the cost is computed from the price cache, a copy of the public LiteLLM "
                 + "price list. Models missing from it are not priced.")
            item("What is counted",
                 "Only requests made through pi or Claude Code. Usage from other tools or websites is not included.")
            item("Privacy",
                 "Only the token counts, model, provider and time are read. Message content is never read, "
                 + "stored or shown. The only network request downloads the public LiteLLM price list. "
                 + "No usage data is sent, and no account or API key is needed.")
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
