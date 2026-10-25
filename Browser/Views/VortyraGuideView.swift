import SwiftUI
import AppIntents

/// Page menu → "Tips & Ideas…": the agent, Siri and Shortcuts examples from
/// the website's Agent Guide (docs/agent/index.html), inside the app. Keep both
/// in step when actions or phrases change.
struct VortyraGuideView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case agent = "Agent"
        case siri = "Siri"
        case shortcuts = "Shortcuts"
        case more = "More"
        var id: String { rawValue }
    }

    private enum Kind {
        case type, say, action, tip

        var symbol: String {
            switch self {
            case .type: return "sparkles"
            case .say: return "mic.fill"
            case .action: return "square.on.square"
            case .tip: return "lightbulb"
            }
        }
    }

    private struct Item: Identifiable {
        let id = UUID()
        let kind: Kind
        let title: String
        let detail: String
    }

    private struct GuideSection: Identifiable {
        let id = UUID()
        let title: String
        let footer: String?
        let items: [Item]
    }

    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .agent

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Show", selection: $page) {
                        ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text(intro(for: page))
                }

                if page == .shortcuts {
                    Section {
                        ShortcutsLink()
                            .shortcutsLinkStyle(.automaticOutline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                ForEach(sections(for: page)) { section in
                    Section {
                        ForEach(section.items) { item in
                            row(item)
                        }
                    } header: {
                        Text(section.title)
                    } footer: {
                        if let footer = section.footer { Text(footer) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Tips & Ideas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ item: Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.kind == .type || item.kind == .say ? "“\(item.title)”" : item.title)
                    .font(.body.weight(.semibold))
                    .textSelection(.enabled)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func intro(for page: Page) -> String {
        switch page {
        case .agent:
            return "Open the AI panel, pick ChatGPT, Local or Cloud, switch on Agent mode and start with a verb like find, open or fill. Anything that could buy, send, post, delete or sign in waits for your approval."
        case .siri:
            return "Say these phrases as written. When Siri asks a question, answer it."
        case .shortcuts:
            return "Search for Vortyra in the Shortcuts app. Each action has an example of what to put in it."
        case .more:
            return "Saved tasks, page watches, Teach mode, Spotlight, Control Center and ideas for automations."
        }
    }

    // MARK: Content (from the website's Agent Guide)

    private func sections(for page: Page) -> [GuideSection] {
        switch page {
        case .agent: return agent
        case .siri: return siri
        case .shortcuts: return shortcuts
        case .more: return more
        }
    }

    private var agent: [GuideSection] {
        [
            GuideSection(title: "Commands", footer: "Start with an action word (find, search, open, click, type, fill, add, download, sort, book…) and the agent takes over. Questions are still answered as normal chat.", items: [
                Item(kind: .type, title: "/do add the cheapest option to the comparison table", detail: "Always sends the request to the agent."),
                Item(kind: .type, title: "/ask what does this contract say about cancellation?", detail: "Always answers as chat about the page, without touching anything."),
                Item(kind: .type, title: "/search when is the next Benfica home game?", detail: "Looks it up on the web and answers with sources, without leaving your page.")
            ]),
            GuideSection(title: "On the page you're reading", footer: nil, items: [
                Item(kind: .type, title: "Find the search box, search for “wireless headphones” and tell me the top 3 results with prices.", detail: ""),
                Item(kind: .type, title: "Fill this contact form with my details and ask for a quote on 20 pallets.", detail: "Your details come from Settings → Autofill Profile. The agent stops before pressing Submit."),
                Item(kind: .type, title: "Close the cookie banner and scroll to the reviews.", detail: ""),
                Item(kind: .type, title: "Go to my carrier's tracking page, enter MSCU1234567 and tell me the ETA.", detail: "")
            ]),
            GuideSection(title: "Data and exports", footer: nil, items: [
                Item(kind: .type, title: "Extract the table of sailing dates on this page and export it as CSV.", detail: ""),
                Item(kind: .type, title: "Collect every PDF link on this page.", detail: ""),
                Item(kind: .type, title: "Compare the price and battery life of these three laptops and make a PDF report.", detail: "Open the three pages in tabs first; “these” means your open tabs.")
            ]),
            GuideSection(title: "Step by step, in the same chat", footer: "A follow-up can use what the previous request found, for up to 30 minutes in the same conversation.", items: [
                Item(kind: .type, title: "Extract the concert dates on this page.", detail: "Then: “Now create the PDF.”"),
                Item(kind: .type, title: "Find the opening hours of the three nearest libraries.", detail: "Then: “Put that in a PDF.”")
            ]),
            GuideSection(title: "Tabs and bookmarks", footer: nil, items: [
                Item(kind: .type, title: "Put all my tabs about Lisbon hotels into a tab group called Trip.", detail: ""),
                Item(kind: .type, title: "Bookmark this page in my Recipes folder.", detail: ""),
                Item(kind: .type, title: "Open the English and Portuguese versions side by side.", detail: ""),
                Item(kind: .type, title: "Translate this page and turn on reader mode.", detail: ""),
                Item(kind: .type, title: "Find “refund” on this page.", detail: "Highlights every match, like Find on Page.")
            ]),
            GuideSection(title: "Research mode", footer: "Start with Research: the agent reads up to 8 sources in the background and writes a short report with sources. Needs the ChatGPT model.", items: [
                Item(kind: .type, title: "Research the best e-bikes under €2000.", detail: ""),
                Item(kind: .type, title: "Research noise-cancelling headphones in tabs and export a PDF report.", detail: "“In tabs” opens the chosen sources in a new tab group."),
                Item(kind: .type, title: "Compare the return policies of three phone shops across websites.", detail: "")
            ]),
            GuideSection(title: "Calendar, Reminders, Mail and Messages", footer: "Everything opens prefilled for you to check. Nothing is saved or sent until you tap Add, Save or Send.", items: [
                Item(kind: .type, title: "Find the next Benfica home match and add it to my calendar.", detail: ""),
                Item(kind: .type, title: "Extract the container table, export it as CSV and email it to me.", detail: ""),
                Item(kind: .type, title: "Find when the passport office opens tomorrow and remind me.", detail: "")
            ])
        ]
    }

    private var siri: [GuideSection] {
        [
            GuideSection(title: "Phrases", footer: "On devices with Apple Intelligence, Siri also understands natural requests about tabs and bookmarks, such as “bookmark this tab in Vortyra” or “switch to my recipes tab in Vortyra”. Closing tabs, deleting bookmarks and clearing history always ask first.", items: [
                Item(kind: .say, title: "Run a browser task with Vortyra", detail: "Siri asks what to do. Answer “find the next Benfica home match and add it to my calendar”. Also: “Ask Vortyra to work on a webpage”."),
                Item(kind: .say, title: "Run Morning tracking with Vortyra", detail: "Runs a saved task by its name. Also: “Start Morning tracking in Vortyra”."),
                Item(kind: .say, title: "Search with Vortyra", detail: "Siri asks what to look for. Matches are highlighted on the page, or the web is searched if they aren't there."),
                Item(kind: .say, title: "Find on this page with Vortyra", detail: "Siri asks what to find, then highlights it."),
                Item(kind: .say, title: "Search my clipboard with Vortyra", detail: "Searches for the text you copied."),
                Item(kind: .say, title: "Open a website with Vortyra", detail: "Siri asks for the address, then opens it."),
                Item(kind: .say, title: "Open a private tab in Vortyra", detail: "Opens a new private tab."),
                Item(kind: .say, title: "Summarize this page with Vortyra", detail: "Shows a summary card for the page on screen."),
                Item(kind: .say, title: "Translate this page with Vortyra", detail: "Siri asks for the language. Say “English”."),
                Item(kind: .say, title: "Ask on-device AI in Vortyra", detail: "Siri asks for your question and answers on the device.")
            ])
        ]
    }

    private var shortcuts: [GuideSection] {
        func a(_ name: String, _ example: String) -> Item { Item(kind: .action, title: name, detail: example) }
        return [
            GuideSection(title: "Browser agent", footer: nil, items: [
                a("Run Browser Task and Get Result", "Task: “Find the ETA for container MSCU1234567”, Starting Website: your carrier's tracking page. Returns the answer, sources and any CSV or PDF."),
                a("Run Saved Browser Task and Get Result", "Saved Task: “Morning tracking”."),
                a("Run Browser Task", "Task: “Put all my tabs about Lisbon into a group called Trip”. Starts it without waiting."),
                a("Run Saved Browser Task", "Saved Task: “Check visa appointments”. Starts it without waiting."),
                a("Open Saved Browser Task", "Runs a saved task in the app."),
                a("Research a Topic", "Topic: “best e-bikes under €2000”, Open Sources in Tabs on, Make PDF Report on. Needs ChatGPT."),
                a("Get Last Browser Task Result", "The answer from the latest finished task, e.g. to paste into a note."),
                a("Watch Page", "Page Address: a product page, Title: “Headphones price”, Check Every: daily."),
                a("Check Watched Pages", "Checks every watch now and returns the ones that changed.")
            ]),
            GuideSection(title: "AI on the page", footer: nil, items: [
                a("Summarize Current Page", "Summarizes the page on screen."),
                a("Ask On-Device AI", "Question: “Rewrite this in plain English: …”. Nothing leaves the device."),
                a("Send Page to Web AI", "Provider: ChatGPT or Gemini, signed in with your own account.")
            ]),
            GuideSection(title: "Open and search", footer: nil, items: [
                a("Open URL in Vortyra", "URL: https://www.ipma.pt"),
                a("Load URL in Vortyra Tab", "Reuses a tab you choose, e.g. your “Morning” tab."),
                a("Search in Vortyra", "Search Text: “price”. Highlights it on the page; searches the web only if it isn't there."),
                a("Search Web in Vortyra", "Search: “Lisbon weather tomorrow”. Always a new tab."),
                a("Search Clipboard in Vortyra", "Copy a word in any app, run it, and Vortyra searches for it."),
                a("Open Websites Side by Side", "First URL: the English page, Second URL: the Portuguese page."),
                a("End Split View", "Goes back to one page.")
            ]),
            GuideSection(title: "Tabs and groups", footer: nil, items: [
                a("New Vortyra Tab", "Opens an empty tab."),
                a("Create Tab in Vortyra", "URL: your bank's website, Private on."),
                a("New Private Vortyra Tab", "Opens a private tab."),
                a("Reopen Last Closed Tab", "Brings back the tab you just closed."),
                a("Switch to Vortyra Tab", "Tab: pick “Recipes” from your open tabs."),
                a("Switch to Tab Group", "Group: Trip."),
                a("Move Tab to Group", "Group: Trip. Moves the current tab there."),
                a("Close Current Vortyra Tab", "Closes the tab on screen."),
                a("Close Tabs in Vortyra", "Choose several. Asks before closing."),
                a("Close Tabs in Group", "Group: Trip, when the trip is booked.")
            ]),
            GuideSection(title: "Navigation and page modes", footer: nil, items: [
                a("Go Back / Go Forward in Vortyra", "Moves through the current tab's history."),
                a("Reload Vortyra Page", "Reloads the page on screen."),
                a("Set Reader Mode", "Enabled on, for a clean article view."),
                a("Set Desktop Site Mode", "Enabled on, when a site hides features on mobile."),
                a("Translate Vortyra Page", "Language: “English”, “Portuguese” or a code like “pt”. On the device."),
                a("Find Text on Page", "Search Text: “cancellation”. Highlights every match.")
            ]),
            GuideSection(title: "Bookmarks, history and saving", footer: nil, items: [
                a("Bookmark Current Page", "Folder: Recipes."),
                a("Open Bookmark in Vortyra", "Bookmark: pick from your Favorites."),
                a("Delete Vortyra Bookmarks", "Choose the bookmarks. Asks before deleting."),
                a("Save Page to Reading List", "Saves the page on screen to read later."),
                a("Open Last Matching History Page", "Search Text: “carbonara” reopens the last page about it."),
                a("Get Recorded Web Searches", "Date: today. Returns what you searched for that day."),
                a("Clear Vortyra History", "Time Frame: last hour. Asks before clearing.")
            ]),
            GuideSection(title: "Export and download", footer: nil, items: [
                a("Export Page as PDF", "Ready for Save File or Send Email."),
                a("Capture Page Screenshot", "An image of the page on screen."),
                a("Copy Page Title and URL", "Ready to paste into a message."),
                a("Download URL in Vortyra", "URL: a link to a PDF or ZIP file."),
                a("Download Direct Page Video", "When the video is a plain file, not a stream.")
            ])
        ]
    }

    private var more: [GuideSection] {
        [
            GuideSection(title: "Ideas to build in Shortcuts", footer: nil, items: [
                Item(kind: .tip, title: "Morning tracking report", detail: "A time-of-day automation runs Run Saved Browser Task and Get Result with your tracking task, then Send Email with the CSV."),
                Item(kind: .tip, title: "Save and summarize", detail: "On the Action button: Summarize Current Page, then Save Page to Reading List."),
                Item(kind: .tip, title: "Daily page check", detail: "An automation runs Check Watched Pages every morning."),
                Item(kind: .tip, title: "Weekend research", detail: "Research a Topic with “Ask Each Time”, then Save File to put the PDF in iCloud Drive."),
                Item(kind: .tip, title: "Find on page by voice", detail: "A shortcut named “Find on page” with Find Text on Page set to “Ask Each Time”.")
            ]),
            GuideSection(title: "Saved tasks and Teach mode", footer: "Saved tasks can run from Shortcuts, Siri, Spotlight, a widget or a Control Center button.", items: [
                Item(kind: .tip, title: "Save as Task", detail: "After a run, tap Save as Task in the AI panel, or open Agent Tasks → New saved task."),
                Item(kind: .tip, title: "Record a New Task", detail: "In Agent Tasks, do the task yourself on the page, tap Stop, then name and save it. Passwords and codes are never recorded.")
            ]),
            GuideSection(title: "Page watches", footer: "Page menu → Watch Page…, pick how often to check and turn on Notify when it changes.", items: [
                Item(kind: .tip, title: "Price or stock", detail: "Watch a product page. Under Advanced, enter the price element (e.g. .price) so other changes don't count."),
                Item(kind: .tip, title: "Deliveries", detail: "Run a saved task instead, like “What is the ETA for container MSCU1234567?”. You're told only when the answer changes."),
                Item(kind: .tip, title: "Openings", detail: "Job boards, apartment listings, visa appointment pages, ticket sales.")
            ]),
            GuideSection(title: "Spotlight, Control Center and widgets", footer: nil, items: [
                Item(kind: .tip, title: "Spotlight", detail: "Type the name of a bookmark or saved task to open it in Vortyra. Choose what appears in Settings → Spotlight."),
                Item(kind: .tip, title: "Control Center", detail: "Add New Private Tab, Search Clipboard, or Run Saved Task (choose which task)."),
                Item(kind: .tip, title: "Home Screen widgets", detail: "Saved Tasks (up to four) and Page Watches with a Changed badge."),
                Item(kind: .tip, title: "Progress", detail: "A running task shows its current step on the Lock Screen and in the Dynamic Island.")
            ])
        ]
    }
}
