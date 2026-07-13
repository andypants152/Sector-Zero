//
//  CRTMetalView.swift
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
//

import Foundation
import MetalKit
import SwiftUI

struct CRTMetalView: View {
    let video: CGATextModeSnapshot

    var body: some View {
        MetalViewRepresentable(video: video)
            .accessibilityLabel("CRT display")
    }
}

#if os(macOS)
private struct MetalViewRepresentable: NSViewRepresentable {
    let video: CGATextModeSnapshot

    func makeCoordinator() -> Coordinator {
        Coordinator(video: video)
    }

    func makeNSView(context: Context) -> MTKView {
        makeMetalView(context: context)
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.update(video: video)
    }
}
#else
private struct MetalViewRepresentable: UIViewRepresentable {
    let video: CGATextModeSnapshot

    func makeCoordinator() -> Coordinator {
        Coordinator(video: video)
    }

    func makeUIView(context: Context) -> MTKView {
        makeMetalView(context: context)
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.update(video: video)
    }
}
#endif

private extension MetalViewRepresentable {
    func makeMetalView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.autoResizeDrawable = true

        let coordinator = context.coordinator
        let frameBuffer = FrameBuffer(width: coordinator.console.pixelWidth, height: coordinator.console.pixelHeight)
        let renderer = CRTRenderer(metalView: view, frameBuffer: frameBuffer) { [weak coordinator] frameBuffer, time in
            coordinator?.render(into: frameBuffer, time: time)
        }
        context.coordinator.renderer = renderer
        view.delegate = renderer

        return view
    }
}

private final class Coordinator {
    let console = TextConsole()
    private let lock = NSLock()
    private var video: CGATextModeSnapshot
    var renderer: CRTRenderer?

    init(video: CGATextModeSnapshot) {
        self.video = video
    }

    func update(video: CGATextModeSnapshot) {
        lock.withLock { self.video = video }
    }

    func render(into frameBuffer: FrameBuffer, time: TimeInterval) {
        let currentVideo: CGATextModeSnapshot = lock.withLock { self.video }
        console.apply(video: currentVideo)
        console.render(into: frameBuffer, time: time)
    }
}
