import AppKit
import SwiftUI

@main
struct TrackpadServerApp: App {
    @State private var server: ServerManager

    init() {
        let manager = ServerManager()
        manager.start()
        _server = State(initialValue: manager)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(server: server)
        } label: {
            Image(systemName: server.menuBarIconName)
        }
        .menuBarExtraStyle(.window)
    }
}
