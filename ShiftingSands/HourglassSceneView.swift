import SwiftUI
import SceneKit

struct HourglassSceneView: UIViewRepresentable {
    @ObservedObject var viewModel: TimerViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = context.coordinator.hourglassScene.scene
        scnView.pointOfView = context.coordinator.hourglassScene.cameraNode
        scnView.delegate = context.coordinator
        scnView.preferredFramesPerSecond = 120
        scnView.antialiasingMode = .multisampling4X
        scnView.isJitteringEnabled = false  // 4X MSAA handles AA; jittering blurs particles through transparent glass
        scnView.backgroundColor = .clear
        scnView.isPlaying = true
        // Force synchronous shader/texture compilation to eliminate fade-in
        scnView.prepare(context.coordinator.hourglassScene.scene, shouldAbortBlock: { false })
        #if DEBUG
        scnView.showsStatistics = true
        #endif

        // Wire up scene ref for test mode data dump
        viewModel.sceneRef = context.coordinator.hourglassScene

        // Set up initial particles based on default physics mode
        let count = viewModel.particleCount
        let size = viewModel.particleSizeMultiplier
        let colors = viewModel.randomColors
        context.coordinator.currentParticleCount = count
        context.coordinator.currentSizeMultiplier = size
        context.coordinator.currentRandomColors = colors
        context.coordinator.currentPhysicsMode = viewModel.physicsMode
        switch viewModel.physicsMode {
        case .metal:
            context.coordinator.hourglassScene.setupInstancedParticles(count: count, sizeMultiplier: size, randomColors: colors)
        case .gpu:
            context.coordinator.hourglassScene.setupMetalParticles(count: count, sizeMultiplier: size, randomColors: colors)
        case .cpu:
            context.coordinator.hourglassScene.setupGranularParticles(count: count, sizeMultiplier: size, randomColors: colors)
        }

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        let coordinator = context.coordinator

        // --- Handle physics mode change ---
        if viewModel.physicsMode != coordinator.currentPhysicsMode {
            // Cancel any in-flight flip and reset coordinator state
            coordinator.hourglassScene.cancelFlip()
            coordinator.isFlipping = false
            coordinator.wasRunning = false

            coordinator.currentPhysicsMode = viewModel.physicsMode
            coordinator.particleCountDebounce?.cancel()
            let count = viewModel.particleCount
            let size = viewModel.particleSizeMultiplier
            let colors = viewModel.randomColors
            coordinator.currentParticleCount = count
            coordinator.currentSizeMultiplier = size
            coordinator.currentRandomColors = colors
            switch viewModel.physicsMode {
            case .metal:
                coordinator.hourglassScene.setupInstancedParticles(count: count, sizeMultiplier: size, randomColors: colors)
            case .gpu:
                coordinator.hourglassScene.setupMetalParticles(count: count, sizeMultiplier: size, randomColors: colors)
            case .cpu:
                coordinator.hourglassScene.setupGranularParticles(count: count, sizeMultiplier: size, randomColors: colors)
            }
        }

        // Count/size slider changes are fully deferred — particles rebuild on next
        // start (flip start detection), reset, or mode change. No idle rebuild.

        // --- Detect flip start ---
        if viewModel.isFlipping && !coordinator.isFlipping {
            coordinator.isFlipping = true

            // Only rebuild particles if count/size/color changed since last setup.
            // Otherwise, keep the current particle state — particles should already
            // be at rest at the bottom from the previous run or initial setup.
            let count = viewModel.particleCount
            let size = viewModel.particleSizeMultiplier
            let colors = viewModel.randomColors
            if count != coordinator.currentParticleCount || size != coordinator.currentSizeMultiplier || colors != coordinator.currentRandomColors {
                coordinator.currentParticleCount = count
                coordinator.currentSizeMultiplier = size
                coordinator.currentRandomColors = colors
                coordinator.particleCountDebounce?.cancel()
                switch coordinator.currentPhysicsMode {
                case .metal:
                    coordinator.hourglassScene.setupInstancedParticles(count: count, sizeMultiplier: size, randomColors: colors)
                case .gpu:
                    coordinator.hourglassScene.setupMetalParticles(count: count, sizeMultiplier: size, randomColors: colors)
                case .cpu:
                    coordinator.hourglassScene.setupGranularParticles(count: count, sizeMultiplier: size, randomColors: colors)
                }
            }

            let vm = viewModel
            coordinator.hourglassScene.flipAndStart {
                Task { @MainActor in vm.completeFlip() }
            }
        }

        // --- Detect flip end ---
        if !viewModel.isFlipping && coordinator.isFlipping {
            coordinator.isFlipping = false
            coordinator.wasRunning = true
        }

        // --- Detect timer stop/reset ---
        if !viewModel.isRunning && coordinator.wasRunning {
            if !viewModel.isComplete {
                // Manual Reset — cancel any in-flight flip and respawn particles
                coordinator.hourglassScene.cancelFlip()
                let count = viewModel.particleCount
                let size = viewModel.particleSizeMultiplier
                let colors = viewModel.randomColors
                coordinator.currentParticleCount = count
                coordinator.currentSizeMultiplier = size
                coordinator.currentRandomColors = colors
                switch coordinator.currentPhysicsMode {
                case .metal:
                    coordinator.hourglassScene.setupInstancedParticles(count: count, sizeMultiplier: size, randomColors: colors)
                case .gpu:
                    coordinator.hourglassScene.setupMetalParticles(count: count, sizeMultiplier: size, randomColors: colors)
                case .cpu:
                    coordinator.hourglassScene.setupGranularParticles(count: count, sizeMultiplier: size, randomColors: colors)
                }
            }
            // Natural completion — leave particles where they are (at rest at bottom)
        }

        coordinator.wasRunning = viewModel.isRunning
        coordinator.currentDuration = viewModel.duration
    }

    class Coordinator: NSObject, SCNSceneRendererDelegate {
        let hourglassScene: HourglassScene
        var wasRunning = false
        var isFlipping = false
        var currentParticleCount: Int = 10000
        var currentSizeMultiplier: Float = 1.0
        var currentRandomColors: Bool = false
        var currentPhysicsMode: TimerViewModel.PhysicsMode = .gpu
        var currentDuration: TimeInterval = 30
        var particleCountDebounce: DispatchWorkItem?
        private var lastUpdateTime: TimeInterval = 0

        override init() {
            self.hourglassScene = HourglassScene()
            super.init()
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            let dt = lastUpdateTime > 0
                ? Float(time - lastUpdateTime)
                : Float(1.0 / 120.0)
            let clampedDt = min(dt, 1.0 / 30.0)

            // Neck friction scales with duration to control flow rate.
            let neckDamping: Float = Float(currentDuration) * 0.02

            // Gravity scaling: full gravity at 5s, reduced for longer durations
            // to slow particle flow. Linear scale: 1.0 at 5s, 0.167 at 30s.
            let gravityScale: Float = max(5.0 / Float(currentDuration), 0.15)

            switch currentPhysicsMode {
            case .metal:
                hourglassScene.metalEngine?.neckDamping = neckDamping
                hourglassScene.metalEngine?.gravity = gravityScale
                hourglassScene.updateInstancedSimulation(dt: clampedDt)
            case .gpu:
                hourglassScene.metalEngine?.neckDamping = neckDamping
                hourglassScene.metalEngine?.gravity = gravityScale
                hourglassScene.updateMetalSimulation(dt: clampedDt)
            case .cpu:
                hourglassScene.granularSim?.neckDamping = neckDamping
                hourglassScene.granularSim?.gravity = gravityScale
                hourglassScene.updateGranularSimulation(dt: clampedDt)
            }

            lastUpdateTime = time
        }


    }
}
