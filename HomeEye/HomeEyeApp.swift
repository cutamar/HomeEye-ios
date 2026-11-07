import SwiftUI
import HomeEyeCore

@main
struct HomeEyeApp: App {
    @StateObject private var store = CameraStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                CameraListView()
            }
            .environmentObject(store)
        }
    }
}
