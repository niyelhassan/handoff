import SwiftUI

@main struct RoutineScoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    init() {
        let created = AppModel()
        AppDelegate.model = created
        _model = StateObject(wrappedValue:created)
    }
    var body: some Scene {
        // The actual window and menu-bar item are native AppKit objects owned by AppDelegate.
        // This inert Settings scene only satisfies SwiftUI.App's Scene requirement.
        Settings {
            EmptyView()
        }
    }
}
