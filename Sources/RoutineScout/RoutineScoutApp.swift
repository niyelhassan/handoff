import SwiftUI
import ScoutCore

@main struct RoutineScoutApp: App {
    @StateObject private var model: AppModel
    init() { let created = AppModel(); _model = StateObject(wrappedValue:created) }
    var body: some Scene {
        MenuBarExtra {
            Text(model.status)
            Button("Automations (\(model.automations.count))") { model.show("home") }
            Button("Activity") { model.show("activity") }
            Divider()
            ForEach(model.automations.filter(\.enabled).prefix(10)) { a in Button(a.name) { model.run(a) }.disabled(model.busy) }
            Divider()
            Menu("Replay an example") { ForEach(Fixtures.shapes,id:\.self) { shape in Button(Fixtures.title(shape)) { model.demo(shape) } } }.disabled(model.busy)
            Divider()
            if model.policy.paused { Button("Resume") { model.pause(0) } } else { Button("Pause for 1 hour") { model.pause(3600) }; Button("Pause until tomorrow") { let tomorrow = Calendar.current.nextDate(after:Date(),matching:DateComponents(hour:9),matchingPolicy:.nextTime) ?? Date().addingTimeInterval(86400); model.pause(tomorrow.timeIntervalSinceNow) } }
            Button("Preferences…") { model.show("preferences") }
            Button("Quit Routine Scout") { model.stop(); NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: { Image(systemName:model.policy.paused ? "pause.circle" : "sparkle.magnifyingglass") }
    }
}
