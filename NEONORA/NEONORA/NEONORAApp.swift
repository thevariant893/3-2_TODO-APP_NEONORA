import SwiftUI
import FirebaseCore
import UIKit

final class NeonoraAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        print("Neonora: Firebase initialized successfully.")
        return true
    }
}

@main
struct NeonoraApp: App {
    @UIApplicationDelegateAdaptor(NeonoraAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
