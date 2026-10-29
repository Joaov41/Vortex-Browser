import Foundation
import WidgetKit

/// Asks WidgetKit and Control Center to reload the Phase 8 widgets and controls after saved tasks or page watches change.
enum AgentWidgetReloader {
    @MainActor
    static func reloadAll() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }
}
