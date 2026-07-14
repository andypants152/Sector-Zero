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
    /// Returns true when CPU-composed text pixels changed and need uploading.
    typealias FrameProvider = (FrameBuffer, TimeInterval) -> Bool

    private struct Uniforms {
        var viewportSize: SIMD2<Float>
        var frameBufferSize: SIMD2<Float>
        var time: Float
    }

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let frameBuffer: FrameBuffer
    private let texture: MTLTexture
    private let startTime: CFTimeInterval
    private let frameProvider: FrameProvider?

    init?(metalView: MTKView, frameBuffer: FrameBuffer = FrameBuffer(), frameProvider: FrameProvider? = nil) {
        guard let device = metalView.device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        self.commandQueue = commandQueue
        self.frameBuffer = frameBuffer
        self.startTime = CACurrentMediaTime()
        self.frameProvider = frameProvider

        metalView.device = device
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.framebufferOnly = true
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = 60

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: frameBuffer.width,
            height: frameBuffer.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            return nil
        }

        self.texture = texture

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

    func submit(frameBuffer update: (FrameBuffer) -> Void) {
        update(frameBuffer)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let elapsedTime = CACurrentMediaTime() - startTime
        if frameProvider?(frameBuffer, elapsedTime) ?? true {
            uploadFrameBuffer()
        }

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
            frameBufferSize: SIMD2<Float>(Float(frameBuffer.width), Float(frameBuffer.height)),
            time: Float(elapsedTime)
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func uploadFrameBuffer() {
        texture.replace(
            region: MTLRegionMake2D(0, 0, frameBuffer.width, frameBuffer.height),
            mipmapLevel: 0,
            withBytes: frameBuffer.pixels,
            bytesPerRow: frameBuffer.bytesPerRow
        )
    }
}
