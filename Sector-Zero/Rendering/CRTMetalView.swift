//
//  CRTMetalView.swift
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
//

import MetalKit
import SwiftUI

struct CRTMetalView: View {
    var body: some View {
        MetalViewRepresentable()
            .accessibilityLabel("CRT display")
    }
}

#if os(macOS)
private struct MetalViewRepresentable: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        makeMetalView(context: context)
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
#else
private struct MetalViewRepresentable: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        makeMetalView(context: context)
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
#endif

private extension MetalViewRepresentable {
    func makeMetalView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.autoResizeDrawable = true

        let demoScene = context.coordinator.demoScene
        let renderer = CRTRenderer(metalView: view) { frameBuffer, time in
            demoScene.render(into: frameBuffer, time: time)
        }
        context.coordinator.renderer = renderer
        view.delegate = renderer

        return view
    }
}

private final class Coordinator {
    let demoScene = FrameBufferDemoScene()
    var renderer: CRTRenderer?
}
