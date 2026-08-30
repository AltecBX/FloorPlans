import SwiftUI
import SwiftData

/// Jerry FieldPlans — contractor field measurement & floor plan capture.
///
/// The app name is intentionally referenced through `AppInfo.appName` so it
/// can be changed in one place. (Internal module and folder names remain
/// "FieldPlan"/"FieldPlanCore"; only user-visible naming changes here.)
enum AppInfo {
    static let appName = "Jerry FieldPlans"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
}

@main
struct FieldPlanApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: ProjectRecord.self,
                PhotoRecord.self,
                NoteRecord.self,
                MeasurementRecord.self,
                ScanRecord.self,
                SnapshotRecord.self,
                TakeoffItemRecord.self,
                AccuracyTestRecord.self
            )
        } catch {
            // A corrupt store at launch is unrecoverable in code; crash with a
            // clear message rather than losing data silently. SwiftData keeps
            // the store file; reinstalling the app preserves project files in
            // Application Support.
            fatalError("Failed to open the FieldPlan database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            ProjectListView()
                .tabItem { Label("Projects", systemImage: "folder.fill") }
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}
