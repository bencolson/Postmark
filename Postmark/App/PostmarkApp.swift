import SwiftUI

@main
struct PostmarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Use Settings scene — it never creates a Dock icon, unlike Window.
        Settings {
            EmptyView()
        }
    }
}
