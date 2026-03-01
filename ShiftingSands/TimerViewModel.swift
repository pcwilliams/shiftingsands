import SwiftUI

@MainActor
class TimerViewModel: ObservableObject {
    @Published var duration: TimeInterval = 5 {
        didSet {
            UserDefaults.standard.set(duration, forKey: "timerDuration")
        }
    }
    @Published var elapsed: TimeInterval = 0
    @Published var isRunning = false
    @Published var isComplete = false
    @Published var isFlipping = false

    @Published var particleCount: Int = 10000 {
        didSet {
            // Persist count for the current mode
            UserDefaults.standard.set(particleCount, forKey: physicsMode.countKey)
        }
    }

    @Published var particleSizeMultiplier: Float = 1.0 {
        didSet {
            UserDefaults.standard.set(particleSizeMultiplier, forKey: physicsMode.sizeKey)
        }
    }

    @Published var randomColors: Bool = false {
        didSet {
            UserDefaults.standard.set(randomColors, forKey: "randomColors")
        }
    }

    enum PhysicsMode: String, CaseIterable {
        case cpu = "CPU"
        case gpu = "GPU"
        case metal = "Metal"

        var maxParticles: Int {
            switch self {
            case .cpu: return 250
            case .gpu: return 10000
            case .metal: return 50000
            }
        }

        var defaultParticles: Int {
            switch self {
            case .cpu: return 100
            case .gpu: return 5000
            case .metal: return 5000
            }
        }

        /// UserDefaults key for this mode's particle count
        var countKey: String {
            "particleCount_\(rawValue)"
        }

        /// UserDefaults key for this mode's particle size multiplier
        var sizeKey: String {
            "particleSize_\(rawValue)"
        }
    }

    @Published var physicsMode: PhysicsMode = .gpu {
        didSet {
            UserDefaults.standard.set(physicsMode.rawValue, forKey: "physicsMode")
            // Recall this mode's last-used count (or default)
            let saved = UserDefaults.standard.integer(forKey: physicsMode.countKey)
            if saved >= 50 {
                particleCount = min(saved, physicsMode.maxParticles)
            } else {
                particleCount = physicsMode.defaultParticles
            }
            // Recall this mode's last-used size (or default 1.0)
            let savedSize = UserDefaults.standard.float(forKey: physicsMode.sizeKey)
            particleSizeMultiplier = (savedSize >= 0.5 && savedSize <= 1.5) ? savedSize : 1.0
        }
    }

    init() {
        // Restore persisted mode
        let mode: PhysicsMode
        if let modeRaw = UserDefaults.standard.string(forKey: "physicsMode"),
           let saved = PhysicsMode(rawValue: modeRaw) {
            mode = saved
        } else {
            mode = .gpu
        }
        _physicsMode = Published(initialValue: mode)

        // Restore this mode's persisted count
        let savedCount = UserDefaults.standard.integer(forKey: mode.countKey)
        if savedCount >= 50 {
            _particleCount = Published(initialValue: min(savedCount, mode.maxParticles))
        } else {
            _particleCount = Published(initialValue: mode.defaultParticles)
        }

        // Restore this mode's persisted size multiplier
        let savedSize = UserDefaults.standard.float(forKey: mode.sizeKey)
        if savedSize >= 0.5 && savedSize <= 1.5 {
            _particleSizeMultiplier = Published(initialValue: savedSize)
        } else {
            _particleSizeMultiplier = Published(initialValue: 1.0)
        }

        // Restore persisted duration (default 5s)
        let savedDuration = UserDefaults.standard.double(forKey: "timerDuration")
        if savedDuration >= 5 && savedDuration <= 30 {
            _duration = Published(initialValue: savedDuration)
        }

        // Restore random colors toggle
        _randomColors = Published(initialValue: UserDefaults.standard.bool(forKey: "randomColors"))
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(elapsed / duration, 1.0)
    }

    var remainingText: String {
        let remaining = max(duration - elapsed, 0)
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var testMode = false
    /// Set by HourglassSceneView coordinator so we can dump particle data
    weak var sceneRef: HourglassScene?

    private var timerTask: Task<Void, Never>?

    /// Phase 1: Trigger the flip animation (timer doesn't start yet)
    func startFlip() {
        guard !isFlipping else { return }
        if isRunning {
            // Stop any in-progress timer before starting fresh
            timerTask?.cancel()
            timerTask = nil
            isRunning = false
        }
        isFlipping = true
        isComplete = false
        elapsed = 0
    }

    /// Cancel current run and immediately restart (flip → timer)
    func restart() {
        reset()
        startFlip()
    }

    /// Phase 2: Called when flip animation completes — starts the actual timer
    func completeFlip() {
        isFlipping = false
        isRunning = true

        timerTask = Task { [weak self] in
            let startDate = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_666_667) // ~60Hz
                guard let self else { return }
                let newElapsed = Date().timeIntervalSince(startDate)
                if newElapsed >= self.duration {
                    self.elapsed = self.duration
                    self.isRunning = false
                    self.isComplete = true
                    if self.testMode {
                        self.dumpTestResults()
                    }
                    return
                }
                self.elapsed = newElapsed
            }
        }
    }

    func reset() {
        timerTask?.cancel()
        timerTask = nil
        isRunning = false
        isFlipping = false
        isComplete = false
        elapsed = 0
    }

    /// Dump spawn state immediately (before any physics runs)
    func dumpSpawnState() {
        guard let scene = sceneRef, let engine = scene.metalEngine else {
            NSLog("[SPAWN] No metal engine available")
            return
        }
        let particles = engine.readPositions()
        let count = particles.count

        var upperCount = 0
        var lowerCount = 0
        var neckCount = 0  // particles near y=0
        var minY: Float = 999
        var maxY: Float = -999

        for p in particles {
            let y = p.positionAndRadius.y
            if y > 0 { upperCount += 1 } else { lowerCount += 1 }
            if abs(y) < 0.05 { neckCount += 1 }
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        var lines = [String]()
        lines.append("=== SPAWN STATE ===")
        lines.append("mode=\(physicsMode.rawValue) count=\(count) radius=\(engine.particleRadius)")
        lines.append("upper=\(upperCount) lower=\(lowerCount) nearNeck=\(neckCount)")
        lines.append("yRange=[\(String(format: "%.4f", minY)), \(String(format: "%.4f", maxY))]")
        lines.append("")

        // Histogram of Y positions in 20 bins
        lines.append("--- Y histogram (20 bins from -0.50 to 0.50) ---")
        var bins = [Int](repeating: 0, count: 20)
        for p in particles {
            let y = p.positionAndRadius.y
            let bin = Int((y + 0.5) / 1.0 * 20.0)
            let clampedBin = max(0, min(19, bin))
            bins[clampedBin] += 1
        }
        for (i, b) in bins.enumerated() {
            let lo = -0.50 + Float(i) * 0.05
            let hi = lo + 0.05
            let bar = String(repeating: "#", count: min(b / 10, 60))
            lines.append(String(format: "[%+.2f,%+.2f) %4d %@", lo, hi, b, bar))
        }

        let text = lines.joined(separator: "\n")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("spawn_state.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        NSLog("[SPAWN] Results written to \(url.path)")
        NSLog("[SPAWN] upper=\(upperCount) lower=\(lowerCount) nearNeck=\(neckCount) yRange=[\(String(format: "%.4f", minY)), \(String(format: "%.4f", maxY))]")
    }

    /// Dump particle positions/velocities to a file for analysis
    private func dumpTestResults() {
        guard let scene = sceneRef, let engine = scene.metalEngine else {
            NSLog("[TEST] No metal engine available")
            return
        }
        let particles = engine.readPositions()
        let count = particles.count

        var upperCount = 0
        var lowerCount = 0
        var sleepingCount = 0
        var deepSleepCount = 0
        var totalSpeed: Float = 0
        var totalAbsVelY: Float = 0
        var maxSpeed: Float = 0

        for p in particles {
            let pos = p.positionAndRadius
            let vel = p.velocityAndPad
            let speed = sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z)
            totalSpeed += speed
            totalAbsVelY += abs(vel.y)
            maxSpeed = max(maxSpeed, speed)
            if pos.y > 0 { upperCount += 1 } else { lowerCount += 1 }
            if vel.w > 15 { sleepingCount += 1 }
            if vel.w > 30 { deepSleepCount += 1 }
        }

        let avgSpeed = count > 0 ? totalSpeed / Float(count) : 0
        let avgAbsVelY = count > 0 ? totalAbsVelY / Float(count) : 0

        var lines = [String]()
        lines.append("=== TEST RESULTS ===")
        lines.append("mode=\(physicsMode.rawValue) count=\(count) duration=\(duration)s")
        lines.append("upper=\(upperCount) lower=\(lowerCount) (\(String(format: "%.1f", Float(lowerCount) / Float(max(count, 1)) * 100))% drained)")
        lines.append("sleeping=\(sleepingCount) deepSleep=\(deepSleepCount)")
        lines.append("avgSpeed=\(String(format: "%.6f", avgSpeed)) avgAbsVelY=\(String(format: "%.6f", avgAbsVelY)) maxSpeed=\(String(format: "%.6f", maxSpeed))")
        lines.append("")
        lines.append("--- Per-particle (idx posX posY posZ velX velY velZ sleepCounter) ---")
        for (i, p) in particles.enumerated() {
            let pos = p.positionAndRadius
            let vel = p.velocityAndPad
            lines.append(String(format: "%d %.4f %.4f %.4f %.4f %.4f %.4f %.0f",
                                i, pos.x, pos.y, pos.z, vel.x, vel.y, vel.z, vel.w))
        }

        let text = lines.joined(separator: "\n")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("test_results.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        NSLog("[TEST] Results written to \(url.path)")
        NSLog("[TEST] upper=\(upperCount) lower=\(lowerCount) sleeping=\(sleepingCount) avgSpeed=\(String(format: "%.6f", avgSpeed))")
    }

    static let presets: [(String, TimeInterval)] = [
        ("5s", 5),
        ("10s", 10),
        ("30s", 30),
    ]
}
