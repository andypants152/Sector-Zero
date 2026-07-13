//
//  ContentView.swift
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
//

import SwiftUI

struct ContentView: View {
    @State private var workspace = SectorZeroWorkspace()

    var body: some View {
        SectorZeroWorkspaceView(workspace: workspace)
            .navigationTitle(workspace.windowTitle)
    }
}

#Preview {
    ContentView()
}
