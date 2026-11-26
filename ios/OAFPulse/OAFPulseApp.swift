import SwiftUI

@main
struct OAFPulseApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .onAppear {
                    store.startInitialLoadIfReady()
                }
                .onOpenURL { url in
                    store.handleIncomingURL(url)
                }
        }
    }
}
