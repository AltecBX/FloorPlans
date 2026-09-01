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
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

    /// What changed in this build, shown in Settings → About.
    ///
    /// Without this there is no way to tell a fresh build from the one before
    /// it — the marketing version alone stays "1.0" forever, so a pull that
    /// silently failed looks identical to one that worked. Both this and
    /// `CURRENT_PROJECT_VERSION` are bumped on every push.
    static let releaseDate = "September 1, 2026"
    static let releaseNotes = "Scan engine: live quality advice and coverage map, sensor sessions recorded (mesh, poses, keyframes), evidence scores on every wall, positioned photos, unscanned-space detection after each save, and tape-test accuracy statistics."

    /// "1.1 (8)" — the string to quote when reporting a problem.
    static var versionAndBuild: String { "\(version) (\(build))" }
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
