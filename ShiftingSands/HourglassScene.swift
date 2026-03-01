import SceneKit
import UIKit

class HourglassScene {

    let scene = SCNScene()
    let cameraNode: SCNNode

    // Container node — groups all hourglass geometry for flip animation.
    // Camera and lights are NOT children (they stay fixed during flip).
    let hourglassContainer = SCNNode()

    private var outerGlassNode = SCNNode()
    private var innerGlassNode = SCNNode()
    private let topCapNode = SCNNode()
    private let bottomCapNode = SCNNode()

    // Granular particle simulation (CPU or GPU)
    private(set) var granularSim: GranularSimulation?
    private(set) var metalEngine: MetalPhysicsEngine?
    private var particleSphereNodes: [SCNNode] = []
    private var particlesContainerNode: SCNNode?

    // Metal instanced rendering — point geometry reads physics buffer directly (zero CPU readback)
    private var rendererNode: SCNNode?

    // Thread safety: protects particleSphereNodes, granularSim, metalEngine
    // from concurrent access between SceneKit render thread and main thread
    private let particleLock = NSLock()

    init() {
        cameraNode = HourglassScene.createCamera()
        buildScene()
    }

    // MARK: - Scene Construction

    private func buildScene() {
        scene.background.contents = UIColor.black

        rebuildGlass()
        buildFrameCaps()

        scene.rootNode.addChildNode(hourglassContainer)

        for light in HourglassScene.createLightingRig() {
            scene.rootNode.addChildNode(light)
        }

        scene.rootNode.addChildNode(cameraNode)

        scene.lightingEnvironment.contents = createGradientEnvironment()
        scene.lightingEnvironment.intensity = 0.08
    }

    // MARK: - Glass

    /// Rebuild glass geometry using the current SandGeometry active profiles.
    /// Called on init and whenever the neck radius changes (particle count change).
    func rebuildGlass() {
        outerGlassNode.removeFromParentNode()
        innerGlassNode.removeFromParentNode()

        outerGlassNode = SCNNode()
        innerGlassNode = SCNNode()

        let outerGeometry = SandGeometry.createRevolutionSurface(
            profile: SandGeometry.activeOuterProfile,
            segments: 64,
            flipNormals: false
        )
        outerGeometry.firstMaterial = HourglassScene.createGlassMaterial()
        outerGlassNode.geometry = outerGeometry
        hourglassContainer.addChildNode(outerGlassNode)

        let innerGeometry = SandGeometry.createRevolutionSurface(
            profile: SandGeometry.activeInnerProfile,
            segments: 64,
            flipNormals: true
        )
        innerGlassNode.geometry = innerGeometry
        innerGlassNode.opacity = 0.0

        let physicsShape = SCNPhysicsShape(
            geometry: innerGeometry,
            options: [.type: SCNPhysicsShape.ShapeType.concavePolyhedron]
        )
        innerGlassNode.physicsBody = SCNPhysicsBody(type: .static, shape: physicsShape)
        innerGlassNode.physicsBody?.friction = 0.4
        innerGlassNode.physicsBody?.restitution = 0.05

        hourglassContainer.addChildNode(innerGlassNode)
    }

    // MARK: - Frame Caps

    private func buildFrameCaps() {
        let capMaterial = SCNMaterial()
        capMaterial.lightingModel = .physicallyBased
        capMaterial.diffuse.contents = UIColor(red: 0.45, green: 0.30, blue: 0.18, alpha: 1.0)
        capMaterial.metalness.contents = 0.1 as NSNumber
        capMaterial.roughness.contents = 0.7 as NSNumber

        let capHeight: CGFloat = 0.025
        let capRadius: CGFloat = 0.18

        let topCap = SCNCylinder(radius: capRadius, height: capHeight)
        topCap.firstMaterial = capMaterial
        topCapNode.geometry = topCap
        topCapNode.position = SCNVector3(0, 0.5125, 0)
        hourglassContainer.addChildNode(topCapNode)

        let bottomCap = SCNCylinder(radius: capRadius, height: capHeight)
        bottomCap.firstMaterial = capMaterial
        bottomCapNode.geometry = bottomCap
        bottomCapNode.position = SCNVector3(0, -0.5125, 0)
        hourglassContainer.addChildNode(bottomCapNode)
    }

    // MARK: - Granular Particle Simulation

    /// Create shared sphere geometry, material, and container node for particles.
    /// Lambert lighting: pure diffuse, no specular/Fresnel — prevents white blowout on particle undersides.
    private func createParticleNodes(radius: Float) -> (SCNSphere, SCNNode) {
        let sphere = SCNSphere(radius: CGFloat(radius))
        sphere.segmentCount = 12
        let mat = SCNMaterial()
        mat.lightingModel = .lambert
        mat.diffuse.contents = UIColor(red: 0.76, green: 0.60, blue: 0.28, alpha: 1.0)
        sphere.firstMaterial = mat

        let container = SCNNode()
        container.name = "particlesContainer"
        hourglassContainer.addChildNode(container)
        particlesContainerNode = container

        return (sphere, container)
    }

    /// Create a palette of colored sphere geometries for random color mode.
    /// Using a small palette (24 colors) allows SceneKit to batch nodes sharing
    /// the same geometry, avoiding N draw calls for N particles.
    /// Lambert lighting: no specular/Fresnel, so particle colors show through cleanly.
    private func createColorPalette(radius: Float, count: Int = 24) -> [SCNSphere] {
        (0..<count).map { i in
            let sphere = SCNSphere(radius: CGFloat(radius))
            sphere.segmentCount = 12
            let mat = SCNMaterial()
            mat.lightingModel = .lambert
            mat.diffuse.contents = UIColor(
                hue: CGFloat(i) / CGFloat(count),
                saturation: 0.7, brightness: 0.85, alpha: 1.0
            )
            sphere.firstMaterial = mat
            return sphere
        }
    }

    /// Set up sphere nodes for the CPU granular simulation.
    /// Adjusts the glass neck width so exactly one particle fits through.
    func setupGranularParticles(count: Int, sizeMultiplier: Float = 1.0, randomColors: Bool = false) {
        particleLock.lock()
        defer { particleLock.unlock() }

        teardownAllParticlesInternal()

        let radius = GranularSimulation.radiusForCount(count, sizeMultiplier: sizeMultiplier)

        // Dynamic neck: inner radius = particle radius + tiny clearance
        // Outer neck radius = inner neck radius + wall thickness
        let neckOuterRadius = radius + SandGeometry.wallThickness + 0.002
        SandGeometry.setNeckRadius(neckOuterRadius)
        rebuildGlass()

        let sim = GranularSimulation(count: count, particleRadius: radius)
        granularSim = sim

        let (sphere, container) = createParticleNodes(radius: radius)
        let palette = randomColors ? createColorPalette(radius: radius) : []

        // Create one SCNNode per particle
        particleSphereNodes = sim.particles.map { particle in
            let node = SCNNode()
            if randomColors {
                node.geometry = palette[Int.random(in: 0..<palette.count)]
            } else {
                node.geometry = sphere
            }
            node.position = SCNVector3(
                particle.position.x,
                particle.position.y,
                particle.position.z
            )
            container.addChildNode(node)
            return node
        }
    }

    /// Remove all particle sphere nodes and nil the simulation
    func teardownGranularParticles() {
        particleLock.lock()
        defer { particleLock.unlock() }
        particlesContainerNode?.removeFromParentNode()
        particlesContainerNode = nil
        particleSphereNodes.removeAll()
        granularSim = nil
    }

    /// Per-frame update — runs CPU physics and syncs node positions
    func updateGranularSimulation(dt: Float) {
        // Capture references under lock, then release before doing work.
        // This prevents priority inversion: the main thread can acquire the lock
        // for setup/teardown while the render thread runs physics unlocked.
        particleLock.lock()
        guard let sim = granularSim else {
            particleLock.unlock()
            return
        }
        let nodes = particleSphereNodes
        particleLock.unlock()

        // Read the current animation-in-flight euler angle for gravity direction
        sim.containerEulerX = hourglassContainer.presentation.eulerAngles.x

        // Step physics
        sim.step(dt: dt)

        // Sync SCNNode positions from simulation
        for i in nodes.indices where i < sim.particles.count {
            let p = sim.particles[i].position
            nodes[i].position = SCNVector3(p.x, p.y, p.z)
        }
    }

    // MARK: - Metal GPU Particle Simulation

    /// Set up sphere nodes driven by GPU physics.
    /// Uses the same neck/glass logic and shared geometry as CPU mode.
    func setupMetalParticles(count: Int, sizeMultiplier: Float = 1.0, randomColors: Bool = false) {
        particleLock.lock()
        defer { particleLock.unlock() }

        teardownAllParticlesInternal()

        let radius = GranularSimulation.radiusForCount(count, sizeMultiplier: sizeMultiplier)

        let neckOuterRadius = radius + SandGeometry.wallThickness + 0.002
        SandGeometry.setNeckRadius(neckOuterRadius)
        rebuildGlass()

        guard let engine = MetalPhysicsEngine(count: count, particleRadius: radius) else {
            // Fallback to CPU if Metal init fails
            let sim = GranularSimulation(count: count, particleRadius: radius)
            granularSim = sim
            let (sphere, container) = createParticleNodes(radius: radius)
            particleSphereNodes = sim.particles.map { particle in
                let node = SCNNode()
                node.geometry = sphere
                node.position = SCNVector3(particle.position.x, particle.position.y, particle.position.z)
                container.addChildNode(node)
                return node
            }
            return
        }
        metalEngine = engine
        let (sphere, container) = createParticleNodes(radius: radius)
        let palette = randomColors ? createColorPalette(radius: radius) : []

        // Create SCNNodes from GPU particle positions
        let particles = engine.readPositions()
        particleSphereNodes = (0..<count).map { i in
            let node = SCNNode()
            if randomColors {
                node.geometry = palette[Int.random(in: 0..<palette.count)]
            } else {
                node.geometry = sphere
            }
            let p = particles[i].positionAndRadius
            node.position = SCNVector3(p.x, p.y, p.z)
            container.addChildNode(node)
            return node
        }
    }

    /// Remove Metal engine and particle nodes
    func teardownMetalParticles() {
        particleLock.lock()
        defer { particleLock.unlock() }
        particlesContainerNode?.removeFromParentNode()
        particlesContainerNode = nil
        particleSphereNodes.removeAll()
        metalEngine = nil
    }

    // MARK: - Metal Instanced Rendering (buffer-backed geometry)

    /// Set up Metal-mode particles: one SCNNode whose geometry reads positions directly
    /// from the GPU physics buffer via SCNGeometrySource(buffer:). No CPU readback.
    /// SceneKit handles all rendering (depth, lighting, passes) through its standard pipeline.
    func setupInstancedParticles(count: Int, sizeMultiplier: Float = 1.0, randomColors: Bool = false) {
        particleLock.lock()
        defer { particleLock.unlock() }

        teardownAllParticlesInternal()

        let radius = GranularSimulation.radiusForCount(count, sizeMultiplier: sizeMultiplier)

        let neckOuterRadius = radius + SandGeometry.wallThickness + 0.002
        SandGeometry.setNeckRadius(neckOuterRadius)
        rebuildGlass()

        guard let engine = MetalPhysicsEngine(count: count, particleRadius: radius) else {
            // Fallback: set up as CPU mode
            let sim = GranularSimulation(count: min(count, 250), particleRadius: GranularSimulation.radiusForCount(min(count, 250), sizeMultiplier: sizeMultiplier))
            granularSim = sim
            let (sphere, container) = createParticleNodes(radius: sim.particles.first?.radius ?? radius)
            particleSphereNodes = sim.particles.map { particle in
                let node = SCNNode()
                node.geometry = sphere
                node.position = SCNVector3(particle.position.x, particle.position.y, particle.position.z)
                container.addChildNode(node)
                return node
            }
            return
        }
        metalEngine = engine
        // Set up per-particle colors and build mesh expansion buffers
        engine.setupColors(random: randomColors)
        engine.buildMeshBuffers()
        engine.expandMeshes()  // Initial expansion for first frame

        let node = SCNNode()
        node.geometry = makeMeshGeometry(engine: engine)
        // Explicit bounding box prevents SceneKit from recomputing bounds
        // from vertex data every frame (which causes flicker and frustum-cull issues)
        node.boundingBox = (
            min: SCNVector3(-0.25, -0.55, -0.25),
            max: SCNVector3(0.25, 0.55, 0.25)
        )
        hourglassContainer.addChildNode(node)
        rendererNode = node
    }

    /// Build triangle geometry from the mesh expansion vertex buffer.
    /// Each particle is an icosahedron (42 verts, 80 faces) with proper normals and per-vertex color.
    private func makeMeshGeometry(engine: MetalPhysicsEngine) -> SCNGeometry? {
        guard let vertexBuf = engine.meshVertexBuffer,
              let indexBuf = engine.meshIndexBuffer else { return nil }

        let stride = MetalPhysicsEngine.meshVertexStride  // 28 bytes

        // Vertex positions: packed_float3 at offset 0
        let positionSource = SCNGeometrySource(
            buffer: vertexBuf,
            vertexFormat: .float3,
            semantic: .vertex,
            vertexCount: engine.meshVertexCount,
            dataOffset: 0,
            dataStride: stride
        )

        // Normals: packed_float3 at offset 12
        let normalSource = SCNGeometrySource(
            buffer: vertexBuf,
            vertexFormat: .float3,
            semantic: .normal,
            vertexCount: engine.meshVertexCount,
            dataOffset: 12,
            dataStride: stride
        )

        // Per-vertex color: uchar4 at offset 24
        let colorSource = SCNGeometrySource(
            buffer: vertexBuf,
            vertexFormat: .uchar4Normalized,
            semantic: .color,
            vertexCount: engine.meshVertexCount,
            dataOffset: 24,
            dataStride: stride
        )

        // Triangle elements from pre-computed index buffer
        let element = SCNGeometryElement(
            buffer: indexBuf,
            primitiveType: .triangles,
            primitiveCount: engine.meshIndexCount / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [positionSource, normalSource, colorSource], elements: [element])

        // Lambert material — vertex colors provide the actual color.
        // Lambert has no specular/Fresnel, preventing white blowout on particle undersides.
        // Slightly below white (0.78) to match perceived brightness of CPU/GPU SCNSphere nodes.
        let mat = SCNMaterial()
        mat.lightingModel = .lambert
        mat.diffuse.contents = UIColor(white: 0.78, alpha: 1.0)
        geometry.firstMaterial = mat

        return geometry
    }

    /// Per-frame update for Metal mode — runs GPU physics and expands meshes.
    /// Geometry is created once in setupInstancedParticles and reused; SceneKit
    /// re-reads the updated vertex buffer contents each frame automatically
    /// (SCNGeometrySource(buffer:) wraps the live MTLBuffer).
    func updateInstancedSimulation(dt: Float) {
        particleLock.lock()
        guard let engine = metalEngine, rendererNode != nil else {
            particleLock.unlock()
            return
        }
        particleLock.unlock()

        engine.containerEulerX = hourglassContainer.presentation.eulerAngles.x
        engine.step(dt: dt)
        engine.expandMeshes()
    }

    /// Remove all particles regardless of mode
    func teardownAllParticles() {
        particleLock.lock()
        defer { particleLock.unlock() }
        teardownAllParticlesInternal()
    }

    /// Internal teardown (caller must hold particleLock)
    private func teardownAllParticlesInternal() {
        rendererNode?.removeFromParentNode()
        rendererNode = nil

        particlesContainerNode?.removeFromParentNode()
        particlesContainerNode = nil
        particleSphereNodes.removeAll()
        granularSim = nil
        metalEngine = nil
    }

    /// Per-frame update — runs GPU physics and syncs node positions
    func updateMetalSimulation(dt: Float) {
        particleLock.lock()
        guard let engine = metalEngine else {
            particleLock.unlock()
            return
        }
        let nodes = particleSphereNodes
        particleLock.unlock()

        engine.containerEulerX = hourglassContainer.presentation.eulerAngles.x
        engine.step(dt: dt)

        let particles = engine.readPositions()
        for i in nodes.indices where i < particles.count {
            let p = particles[i].positionAndRadius
            nodes[i].position = SCNVector3(p.x, p.y, p.z)
        }
    }

    // MARK: - Flip Animation

    /// Flip the hourglass 180°. Particles tumble with real physics as gravity rotates.
    func flipAndStart(completion: @escaping () -> Void) {
        let flipAction = SCNAction.rotateBy(
            x: .pi, y: 0, z: 0,
            duration: 1.2
        )
        flipAction.timingMode = .easeInEaseOut

        hourglassContainer.runAction(flipAction) { [weak self] in
            guard let self else { return }

            // Snap rotation back to identity (glass is symmetric)
            self.hourglassContainer.eulerAngles = SCNVector3(0, 0, 0)

            // Transform particle positions/velocities to match snap-back
            self.particleLock.lock()
            if let engine = self.metalEngine {
                // GPU / Metal instanced path
                engine.snapAfterFlip()
                if self.rendererNode != nil {
                    // Metal instanced mode: update mesh vertices to match snapped positions.
                    // The action completion fires AFTER renderer(updateAtTime:) already ran
                    // expandMeshes() with pre-snap positions. Without this, the vertex buffer
                    // is one frame stale and shows particles at their pre-snap locations in
                    // the now-upright container — causing a visible flash.
                    engine.expandMeshes()
                } else {
                    // GPU mode with readback — sync node positions
                    let particles = engine.readPositions()
                    for i in self.particleSphereNodes.indices where i < particles.count {
                        let p = particles[i].positionAndRadius
                        self.particleSphereNodes[i].position = SCNVector3(p.x, p.y, p.z)
                    }
                }
            } else if let sim = self.granularSim {
                // CPU path
                sim.snapAfterFlip()
                for i in self.particleSphereNodes.indices where i < sim.particles.count {
                    let p = sim.particles[i].position
                    self.particleSphereNodes[i].position = SCNVector3(p.x, p.y, p.z)
                }
            }
            self.particleLock.unlock()

            completion()
        }
    }

    /// Cancel a flip in progress (e.g. if reset is called during flip)
    func cancelFlip() {
        hourglassContainer.removeAllActions()
        hourglassContainer.eulerAngles = SCNVector3(0, 0, 0)
    }

    // MARK: - Materials

    static func createGlassMaterial() -> SCNMaterial {
        let glass = SCNMaterial()
        glass.lightingModel = .blinn
        glass.diffuse.contents = UIColor(white: 1.0, alpha: 0.10)
        glass.specular.contents = UIColor(white: 1.0, alpha: 0.15)
        glass.shininess = 30.0
        glass.fresnelExponent = 3.0
        glass.transparency = 1.0
        glass.transparencyMode = .dualLayer
        glass.isDoubleSided = true
        glass.readsFromDepthBuffer = true
        glass.writesToDepthBuffer = false
        glass.blendMode = .alpha
        return glass
    }

    // MARK: - Camera

    static func createCamera() -> SCNNode {
        let node = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.zNear = 0.1
        camera.zFar = 10.0
        camera.wantsHDR = true
        camera.bloomIntensity = 0.0
        camera.bloomThreshold = 5.0
        camera.bloomBlurRadius = 0.0
        // Lock exposure to prevent gradual brightness shift on startup.
        // HDR auto-exposure adaptation starts dim and brightens over ~2 minutes.
        // Lock at EV 2 (the approximate level auto-exposure settles to) so
        // brightness matches the "fully adapted" look from the start.
        camera.minimumExposure = 4
        camera.maximumExposure = 4
        camera.exposureAdaptationBrighteningSpeedFactor = 100
        camera.exposureAdaptationDarkeningSpeedFactor = 100
        camera.wantsDepthOfField = true
        camera.focusDistance = 3.0
        camera.fStop = 11.0  // deep focus — keeps small particles sharp at high counts
        camera.motionBlurIntensity = 0.0
        camera.screenSpaceAmbientOcclusionIntensity = 0.15
        camera.screenSpaceAmbientOcclusionRadius = 0.05
        node.camera = camera
        node.position = SCNVector3(0.0, 0.05, 3.0)
        node.look(at: SCNVector3(0, -0.02, 0))
        return node
    }

    // MARK: - Lighting

    static func createLightingRig() -> [SCNNode] {
        var lights: [SCNNode] = []

        // Key light: warm directional from upper right
        let keyNode = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 120
        keyLight.temperature = 5000
        keyLight.castsShadow = true
        keyLight.shadowRadius = 3.0
        keyLight.shadowSampleCount = 8
        keyLight.shadowMode = .deferred
        keyLight.shadowColor = UIColor(white: 0, alpha: 0.5)
        keyNode.light = keyLight
        keyNode.position = SCNVector3(1.0, 2.0, 1.5)
        keyNode.look(at: SCNVector3(0, 0, 0))
        lights.append(keyNode)

        // Front fill: illuminates from camera direction
        let frontNode = SCNNode()
        let frontLight = SCNLight()
        frontLight.type = .directional
        frontLight.intensity = 100
        frontLight.temperature = 4500
        frontLight.castsShadow = false
        frontNode.light = frontLight
        frontNode.position = SCNVector3(0, 0.3, 2.0)
        frontNode.look(at: SCNVector3(0, 0, 0))
        lights.append(frontNode)

        // Fill light: cooler, from left
        let fillNode = SCNNode()
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 60
        fillLight.temperature = 6500
        fillLight.castsShadow = false
        fillNode.light = fillLight
        fillNode.position = SCNVector3(-1.5, 0.5, 1.0)
        fillNode.look(at: SCNVector3(0, 0, 0))
        lights.append(fillNode)

        // Rim light: edge highlight from behind
        let rimNode = SCNNode()
        let rimLight = SCNLight()
        rimLight.type = .directional
        rimLight.intensity = 60
        rimLight.temperature = 5500
        rimLight.castsShadow = false
        rimNode.light = rimLight
        rimNode.position = SCNVector3(0.5, 1.0, -1.5)
        rimNode.look(at: SCNVector3(0, 0, 0))
        lights.append(rimNode)

        // Bottom fill: subtle lift to prevent pure black underneath
        let bottomNode = SCNNode()
        let bottomLight = SCNLight()
        bottomLight.type = .omni
        bottomLight.intensity = 8
        bottomLight.temperature = 4500
        bottomLight.attenuationStartDistance = 0.5
        bottomLight.attenuationEndDistance = 3.0
        bottomNode.light = bottomLight
        bottomNode.position = SCNVector3(0, -0.8, 0.5)
        lights.append(bottomNode)

        return lights
    }

    // MARK: - Environment

    private func createGradientEnvironment() -> UIImage {
        let size = CGSize(width: 256, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let colours = [
                UIColor(white: 0.15, alpha: 1.0).cgColor,
                UIColor(white: 0.05, alpha: 1.0).cgColor,
            ]
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colours as CFArray,
                locations: [0.0, 1.0]
            )!
            ctx.cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: size.height),
                options: []
            )
        }
    }
}
