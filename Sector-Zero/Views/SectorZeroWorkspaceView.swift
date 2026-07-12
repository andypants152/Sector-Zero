//
//  SectorZeroWorkspaceView.swift
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
//

import SwiftUI

struct SectorZeroWorkspaceView: View {
    var body: some View {
        VStack(spacing: 16) {
            header
            CRTMetalView()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.sectorScreenBorder, lineWidth: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .layoutPriority(1)
            footer
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sectorWorkspace)
    }

    private var header: some View {
        HStack {
            Text("SECTOR ZERO")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.sectorText)
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack {
            Text("DISPLAY OFFLINE")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.sectorMutedText)
            Spacer(minLength: 0)
        }
    }
}

private extension Color {
    static let sectorWorkspace = Color(red: 0.015, green: 0.017, blue: 0.016)
    static let sectorText = Color(red: 0.70, green: 0.82, blue: 0.72)
    static let sectorMutedText = Color(red: 0.34, green: 0.46, blue: 0.38)
    static let sectorScreenBorder = Color(red: 0.10, green: 0.18, blue: 0.13)
}

#Preview {
    SectorZeroWorkspaceView()
}
