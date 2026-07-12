//
//  CRTRenderer.swift
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
//

import Foundation
import Metal
import MetalKit
import QuartzCore

final class CRTRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var viewportSize: SIMD2<Float>
        var time: Float
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let startTime: CFTimeInterval

    init?(metalView: MTKView) {
        guard let device = metalView.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.startTime = CACurrentMediaTime()

        metalView.device = device
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.framebufferOnly = true
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = 60

        do {
            let library = try device.makeDefaultLibrary(bundle: .main)
            guard let vertexFunction = library.makeFunction(name: "crtVertex"),
                  let fragmentFunction = library.makeFunction(name: "crtFragment") else {
                return nil
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "CRT Display Pipeline"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat

            self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }

        super.init()
    }

    func submit(framebuffer: CRTFramebuffer?) {
        _ = framebuffer
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let width = max(Float(view.drawableSize.width), 1)
        let height = max(Float(view.drawableSize.height), 1)
        var uniforms = Uniforms(
            viewportSize: SIMD2<Float>(width, height),
            time: Float(CACurrentMediaTime() - startTime)
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
