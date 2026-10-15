import SwiftUI
import WidgetKit

@main
struct VortyraWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NewPrivateTabControl()
        SearchClipboardControl()
        RunSavedTaskControl()
        SavedTasksWidget()
        PageWatchesWidget()
        AgentRunLiveActivity()
    }
}
