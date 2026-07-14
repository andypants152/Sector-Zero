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
    let preferredFramesPerSecond: Int

    var body: some View {
        MetalViewRepresentable(video: video, preferredFramesPerSecond: preferredFramesPerSecond)
            .accessibilityLabel("CRT display")
    }
}

#if os(macOS)
private struct MetalViewRepresentable: NSViewRepresentable {
    let video: CGATextModeSnapshot
    let preferredFramesPerSecond: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(video: video)
    }

    func makeNSView(context: Context) -> MTKView {
        makeMetalView(context: context)
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.update(video: video)
        nsView.preferredFramesPerSecond = preferredFramesPerSecond
    }
}
#else
private struct MetalViewRepresentable: UIViewRepresentable {
    let video: CGATextModeSnapshot
    let preferredFramesPerSecond: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(video: video)
    }

    func makeUIView(context: Context) -> MTKView {
        makeMetalView(context: context)
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.update(video: video)
        uiView.preferredFramesPerSecond = preferredFramesPerSecond
    }
}
#endif

private extension MetalViewRepresentable {
    func makeMetalView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.autoResizeDrawable = true

        let coordinator = context.coordinator
        let frameBuffer = FrameBuffer(width: coordinator.console.pixelWidth, height: coordinator.console.pixelHeight)
        view.preferredFramesPerSecond = preferredFramesPerSecond
        let renderer = CRTRenderer(metalView: view, frameBuffer: frameBuffer) { [weak coordinator] frameBuffer, time in
            coordinator?.render(into: frameBuffer, time: time) ?? false
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
    private var renderedVideo: CGATextModeSnapshot?
    private var renderedBlinkPhase: Int?
    var renderer: CRTRenderer?

    init(video: CGATextModeSnapshot) {
        self.video = video
    }

    func update(video: CGATextModeSnapshot) {
        lock.withLock { self.video = video }
    }

    func render(into frameBuffer: FrameBuffer, time: TimeInterval) -> Bool {
        let currentVideo: CGATextModeSnapshot = lock.withLock { self.video }
        let blinkPhase = Int((time / 0.5).rounded(.down))
        let needsTextUpdate = renderedVideo.map { !sameDisplayContent($0, currentVideo) } ?? true
        guard needsTextUpdate || renderedBlinkPhase != blinkPhase else { return false }
        if needsTextUpdate {
            console.apply(video: currentVideo)
            renderedVideo = currentVideo
        }
        console.render(into: frameBuffer, time: time)
        renderedBlinkPhase = blinkPhase
        return true
    }

    /// CGA status is sampled by the guest but does not alter visible pixels.
    private func sameDisplayContent(_ lhs: CGATextModeSnapshot, _ rhs: CGATextModeSnapshot) -> Bool {
        lhs.displayMode == rhs.displayMode &&
        lhs.cells == rhs.cells &&
        lhs.cursorPosition == rhs.cursorPosition &&
        lhs.cursorStartLine == rhs.cursorStartLine &&
        lhs.cursorEndLine == rhs.cursorEndLine
    }
}
