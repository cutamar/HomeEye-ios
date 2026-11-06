import SwiftUI
import HomeEyeCore

@main
struct HomeEyeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("HomeEye \(HomeEyeCoreInfo.version)")
        }
    }
}
