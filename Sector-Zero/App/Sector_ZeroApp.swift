//
//  Sector_ZeroApp.swift
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
//

import SwiftUI

@main
struct Sector_ZeroApp: App {
    @State private var workspace = SectorZeroWorkspace()

    var body: some Scene {
        WindowGroup {
            SectorZeroWorkspaceView(workspace: workspace)
                .navigationTitle(workspace.windowTitle)
        }
        .defaultSize(width: 1_280, height: 800)
        .windowResizability(.contentMinSize)

        #if os(macOS)
        WindowGroup("Floppy Library", id: "floppy-library") {
            FloppyLibraryWindow(workspace: workspace)
        }
        #endif
    }
}
