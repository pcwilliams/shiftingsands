import Metal
import simd
/// GPU particle layout — must match ParticlePhysics.metal GPUParticle
struct GPUParticle {
    var positionAndRadius: SIMD4<Float>  // xyz = position, w = radius
    var velocityAndPad: SIMD4<Float>     // xyz = velocity, w = sleep counter
}

/// Uniforms passed to the physics compute kernel each substep
struct PhysicsUniforms {
    var gravity: Float
    var damping: Float
    var restitution: Float
    var friction: Float
    var subDt: Float
    var containerEulerX: Float
    var chamberBottom: Float
    var chamberTop: Float
    var particleCount: UInt32
    var neckDamping: Float
    var neckHalfHeight: Float
}

class MetalPhysicsEngine {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let physicsPipeline: MTLComputePipelineState
    private let snapPipeline: MTLComputePipelineState
    private let meshExpansionPipeline: MTLComputePipelineState

    // Double-buffered particle data
    private var bufferA: MTLBuffer
    private var bufferB: MTLBuffer
    private var profileBuffer: MTLBuffer

    // Mesh expansion: subdivided icosahedron per particle (42 verts, 80 faces, 240 indices)
    static let verticesPerParticle = 42
    static let indicesPerParticle = 240
    static let meshVertexStride = 28  // packed_float3 pos + packed_float3 normal + uchar4 color
    private(set) var meshVertexBuffer: MTLBuffer?
    private(set) var meshIndexBuffer: MTLBuffer?
    private(set) var meshVertexCount: Int = 0
    private(set) var meshIndexCount: Int = 0
    private(set) var colorBuffer: MTLBuffer?

    private(set) var particleCount: Int
    private(set) var particleRadius: Float

    // Physics config
    var gravity: Float = 1.0
    var damping: Float = 0.05
    var restitution: Float = 0.02
    var friction: Float = 0.6
    var containerEulerX: Float = 0.0

    // Neck friction — extra damping near the constriction, scaled by duration
    var neckDamping: Float = 0.0
    let neckHalfHeight: Float = 0.10

    /// Read-only access to current position buffer (for instanced rendering — zero copy)
    var currentPositionBuffer: MTLBuffer { bufferA }

    /// Metal device for creating render pipelines
    var metalDevice: MTLDevice { device }

    // Hourglass bounds
    let chamberBottom: Float = -0.48
    let chamberTop: Float = 0.48

    /// Adaptive substeps — fewer for large particle counts
    var substeps: Int {
        if particleCount > 10000 { return 1 }
        if particleCount > 3000 { return 2 }
        if particleCount > 1500 { return 3 }
        return 4
    }

    private let threadsPerThreadgroup = 256

    // MARK: - Initialization

    static var isAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    init?(count: Int, particleRadius: Float) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.particleCount = count
        self.particleRadius = particleRadius

        // Compile shaders
        guard let library = device.makeDefaultLibrary(),
              let physicsFunc = library.makeFunction(name: "physicsStep"),
              let snapFunc = library.makeFunction(name: "snapAfterFlip"),
              let meshFunc = library.makeFunction(name: "expandMeshes") else {
            return nil
        }

        do {
            self.physicsPipeline = try device.makeComputePipelineState(function: physicsFunc)
            self.snapPipeline = try device.makeComputePipelineState(function: snapFunc)
            self.meshExpansionPipeline = try device.makeComputePipelineState(function: meshFunc)
        } catch {
            return nil
        }

        // Allocate particle buffers (storageModeShared for zero-copy CPU/GPU access)
        let bufferSize = MemoryLayout<GPUParticle>.stride * max(count, 1)
        guard let a = device.makeBuffer(length: bufferSize, options: .storageModeShared),
              let b = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            return nil
        }
        self.bufferA = a
        self.bufferB = b

        // Build profile lookup table
        let profileData = MetalPhysicsEngine.buildProfileLookup()
        guard let pBuf = device.makeBuffer(
            bytes: profileData,
            length: MemoryLayout<Float>.stride * profileData.count,
            options: .storageModeShared
        ) else {
            return nil
        }
        self.profileBuffer = pBuf

        // Spawn particles in hex-packed lattice from bottom up
        spawnParticles(count: count, radius: particleRadius)
    }

    // MARK: - Profile Lookup Table

    /// Pre-compute 256-entry radius lookup covering Y range [-0.5, 0.5]
    private static func buildProfileLookup() -> [Float] {
        var table = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let y = -0.5 + Float(i) / 255.0 * 1.0
            table[i] = SandGeometry.innerRadiusAt(y: y) - 0.003
        }
        return table
    }

    // MARK: - Particle Spawning

    /// Spawn particles in hex close-packed lattice filling lower chamber.
    /// Uses shared packing algorithm from GranularSimulation.
    private func spawnParticles(count: Int, radius: Float) {
        let positions = GranularSimulation.packedPositions(count: count, particleRadius: radius)
        let ptr = bufferA.contents().bindMemory(to: GPUParticle.self, capacity: count)

        for i in 0..<count {
            let pos = positions[i]
            ptr[i] = GPUParticle(
                positionAndRadius: SIMD4<Float>(pos.x, pos.y, pos.z, radius),
                velocityAndPad: SIMD4<Float>(0, 0, 0, 0)
            )
        }

        // Copy to buffer B as well
        memcpy(bufferB.contents(), bufferA.contents(),
               MemoryLayout<GPUParticle>.stride * count)
    }

    // MARK: - Physics Step

    /// Run one frame of physics (multiple substeps on GPU)
    func step(dt: Float) {
        stepGPU(dt: dt)
    }

    private func stepGPU(dt: Float) {
        guard particleCount > 0 else { return }

        let subs = substeps
        let subDt = dt / Float(subs)

        let threadgroupSize = MTLSize(width: threadsPerThreadgroup, height: 1, depth: 1)
        let gridSize = MTLSize(
            width: (particleCount + threadsPerThreadgroup - 1) / threadsPerThreadgroup * threadsPerThreadgroup,
            height: 1, depth: 1
        )

        for _ in 0..<subs {
            // Fill uniforms
            var uniforms = PhysicsUniforms(
                gravity: gravity,
                damping: damping,
                restitution: restitution,
                friction: friction,
                subDt: subDt,
                containerEulerX: containerEulerX,
                chamberBottom: chamberBottom,
                chamberTop: chamberTop,
                particleCount: UInt32(particleCount),
                neckDamping: neckDamping,
                neckHalfHeight: neckHalfHeight
            )

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                return
            }

            encoder.setComputePipelineState(physicsPipeline)
            encoder.setBuffer(bufferA, offset: 0, index: 0)  // read
            encoder.setBuffer(bufferB, offset: 0, index: 1)  // write
            encoder.setBuffer(profileBuffer, offset: 0, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<PhysicsUniforms>.stride, index: 3)
            encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
            encoder.endEncoding()

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            // Swap buffers
            swap(&bufferA, &bufferB)
        }
    }

    // MARK: - Snap After Flip

    /// Transform particle positions/velocities after container snaps from π to 0
    func snapAfterFlip() {
        guard particleCount > 0 else { return }

        var count = UInt32(particleCount)

        let threadgroupSize = MTLSize(width: threadsPerThreadgroup, height: 1, depth: 1)
        let gridSize = MTLSize(
            width: (particleCount + threadsPerThreadgroup - 1) / threadsPerThreadgroup * threadsPerThreadgroup,
            height: 1, depth: 1
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(snapPipeline)
        encoder.setBuffer(bufferA, offset: 0, index: 0)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        containerEulerX = 0
    }

    // MARK: - Mesh Expansion

    /// Fill the per-particle color buffer. When `random` is true, each particle
    /// gets a random HSB color; otherwise all particles get golden sand.
    func setupColors(random: Bool) {
        let bufSize = MemoryLayout<UInt32>.stride * max(particleCount, 1)
        guard let buf = device.makeBuffer(length: bufSize, options: .storageModeShared) else { return }
        let ptr = buf.contents().bindMemory(to: UInt8.self, capacity: particleCount * 4)

        if random {
            for i in 0..<particleCount {
                // Random hue, fixed saturation/brightness → convert to RGB
                let hue = Float.random(in: 0...1)
                let (r, g, b) = hsbToRGB(h: hue, s: 0.7, b: 0.85)
                ptr[i * 4 + 0] = UInt8(r * 255)
                ptr[i * 4 + 1] = UInt8(g * 255)
                ptr[i * 4 + 2] = UInt8(b * 255)
                ptr[i * 4 + 3] = 255
            }
        } else {
            // Golden sand: (0.76, 0.60, 0.28)
            for i in 0..<particleCount {
                ptr[i * 4 + 0] = 194  // 0.76 * 255
                ptr[i * 4 + 1] = 153  // 0.60 * 255
                ptr[i * 4 + 2] = 71   // 0.28 * 255
                ptr[i * 4 + 3] = 255
            }
        }
        colorBuffer = buf
    }

    /// HSB to RGB conversion (all values 0-1)
    private func hsbToRGB(h: Float, s: Float, b: Float) -> (Float, Float, Float) {
        let c = b * s
        let x = c * (1 - abs(fmod(h * 6, 2) - 1))
        let m = b - c
        let (r1, g1, b1): (Float, Float, Float)
        switch Int(h * 6) % 6 {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return (r1 + m, g1 + m, b1 + m)
    }

    /// Build mesh vertex + index buffers for the current particle count.
    /// Index buffer is static (same octahedron topology repeated per particle).
    func buildMeshBuffers() {
        let vCount = particleCount * Self.verticesPerParticle
        let iCount = particleCount * Self.indicesPerParticle

        // Vertex buffer: 28 bytes per vertex (packed_float3 pos + packed_float3 normal + uchar4 color)
        let vSize = vCount * Self.meshVertexStride
        guard let vBuf = device.makeBuffer(length: max(vSize, 1), options: .storageModeShared) else { return }

        // Build index buffer on CPU (static pattern: same 240 indices per particle, offset by vertex base)
        // Subdivided icosahedron: 20 original faces × 4 sub-triangles = 80 faces × 3 = 240 indices
        let templateIndices: [UInt32] = [
            0, 12, 14,  11, 13, 12,  5, 14, 13,  12, 13, 14,
            0, 14, 16,  5, 15, 14,  1, 16, 15,  14, 15, 16,
            0, 16, 18,  1, 17, 16,  7, 18, 17,  16, 17, 18,
            0, 18, 20,  7, 19, 18,  10, 20, 19,  18, 19, 20,
            0, 20, 12,  10, 21, 20,  11, 12, 21,  20, 21, 12,
            1, 15, 23,  5, 22, 15,  9, 23, 22,  15, 22, 23,
            5, 13, 25,  11, 24, 13,  4, 25, 24,  13, 24, 25,
            11, 21, 27,  10, 26, 21,  2, 27, 26,  21, 26, 27,
            10, 19, 29,  7, 28, 19,  6, 29, 28,  19, 28, 29,
            7, 17, 31,  1, 30, 17,  8, 31, 30,  17, 30, 31,
            3, 32, 34,  9, 33, 32,  4, 34, 33,  32, 33, 34,
            3, 34, 36,  4, 35, 34,  2, 36, 35,  34, 35, 36,
            3, 36, 38,  2, 37, 36,  6, 38, 37,  36, 37, 38,
            3, 38, 40,  6, 39, 38,  8, 40, 39,  38, 39, 40,
            3, 40, 32,  8, 41, 40,  9, 32, 41,  40, 41, 32,
            4, 33, 25,  9, 22, 33,  5, 25, 22,  33, 22, 25,
            2, 35, 27,  4, 24, 35,  11, 27, 24,  35, 24, 27,
            6, 37, 29,  2, 26, 37,  10, 29, 26,  37, 26, 29,
            8, 39, 31,  6, 28, 39,  7, 31, 28,  39, 28, 31,
            9, 41, 23,  8, 30, 41,  1, 23, 30,  41, 30, 23,
        ]

        var indices = [UInt32]()
        indices.reserveCapacity(iCount)
        for i in 0..<particleCount {
            let base = UInt32(i * Self.verticesPerParticle)
            for idx in templateIndices {
                indices.append(base + idx)
            }
        }

        guard let iBuf = device.makeBuffer(
            bytes: indices,
            length: MemoryLayout<UInt32>.stride * iCount,
            options: .storageModeShared
        ) else { return }

        meshVertexBuffer = vBuf
        meshIndexBuffer = iBuf
        meshVertexCount = vCount
        meshIndexCount = iCount
    }

    /// Run the mesh expansion compute kernel: particle positions → icosahedron vertices.
    /// Call after step() each frame.
    func expandMeshes() {
        guard particleCount > 0, let vertexBuf = meshVertexBuffer, let colBuf = colorBuffer else { return }

        let totalThreads = particleCount * Self.verticesPerParticle
        var count = UInt32(particleCount)
        var radius = particleRadius

        let threadgroupSize = MTLSize(width: threadsPerThreadgroup, height: 1, depth: 1)
        let gridSize = MTLSize(
            width: (totalThreads + threadsPerThreadgroup - 1) / threadsPerThreadgroup * threadsPerThreadgroup,
            height: 1, depth: 1
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(meshExpansionPipeline)
        encoder.setBuffer(bufferA, offset: 0, index: 0)      // particle positions
        encoder.setBuffer(vertexBuf, offset: 0, index: 1)     // output vertices
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 2)
        encoder.setBytes(&radius, length: MemoryLayout<Float>.stride, index: 3)
        encoder.setBuffer(colBuf, offset: 0, index: 4)        // per-particle colors
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Read Back Positions

    /// Read particle positions from current GPU buffer for SCNNode sync (safe copy)
    func readPositions() -> [GPUParticle] {
        let ptr = bufferA.contents().bindMemory(to: GPUParticle.self, capacity: particleCount)
        return Array(UnsafeBufferPointer(start: ptr, count: particleCount))
    }

    // MARK: - Reset

    /// Reinitialize particles in lower chamber
    func resetToBottom(count: Int, particleRadius: Float) {
        self.particleCount = count
        self.particleRadius = particleRadius

        // Reallocate buffers if needed
        let needed = MemoryLayout<GPUParticle>.stride * max(count, 1)
        if bufferA.length < needed {
            guard let a = device.makeBuffer(length: needed, options: .storageModeShared),
                  let b = device.makeBuffer(length: needed, options: .storageModeShared) else {
                return
            }
            bufferA = a
            bufferB = b
        }

        // Rebuild profile lookup (neck may have changed)
        let profileData = MetalPhysicsEngine.buildProfileLookup()
        guard let pBuf = device.makeBuffer(
            bytes: profileData,
            length: MemoryLayout<Float>.stride * profileData.count,
            options: .storageModeShared
        ) else {
            return
        }
        profileBuffer = pBuf

        spawnParticles(count: count, radius: particleRadius)
    }
}
