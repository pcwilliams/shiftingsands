import Testing
import Foundation
import simd
@testable import ShiftingSands

struct CPUPhysicsTests {

    // MARK: - Gravity

    @Test func gravityMovesParticleDown() {
        let sim = GranularSimulation(count: 1, particleRadius: 0.02)
        // Place particle in mid-air in lower chamber
        sim.particles[0] = SimParticle(
            position: SIMD3<Float>(0, -0.2, 0),
            velocity: .zero,
            radius: 0.02
        )
        let startY = sim.particles[0].position.y
        sim.step(dt: 1.0 / 60.0)
        #expect(sim.particles[0].position.y < startY, "Particle should fall under gravity")
    }

    // MARK: - Floor Bounce

    @Test func particleStaysAboveFloor() {
        let sim = GranularSimulation(count: 1, particleRadius: 0.02)
        // Place particle at the floor
        sim.particles[0] = SimParticle(
            position: SIMD3<Float>(0, -0.48 + 0.02, 0),
            velocity: SIMD3<Float>(0, -1.0, 0),
            radius: 0.02
        )
        for _ in 0..<100 {
            sim.step(dt: 1.0 / 60.0)
        }
        let minY = sim.particles[0].position.y - sim.particles[0].radius
        #expect(minY >= -0.49, "Particle should not penetrate the floor (y-r=\(minY))")
    }

    // MARK: - Sphere-Sphere Collision

    @Test func overlappingParticlesSeparate() {
        let sim = GranularSimulation(count: 2, particleRadius: 0.02)
        // Place two particles overlapping at the bottom
        sim.particles[0] = SimParticle(
            position: SIMD3<Float>(0.0, -0.3, 0.0),
            velocity: .zero,
            radius: 0.02
        )
        sim.particles[1] = SimParticle(
            position: SIMD3<Float>(0.01, -0.3, 0.0),  // overlap: distance < 0.04
            velocity: .zero,
            radius: 0.02
        )
        for _ in 0..<60 {
            sim.step(dt: 1.0 / 60.0)
        }
        let dist = simd_length(sim.particles[0].position - sim.particles[1].position)
        let minDist = sim.particles[0].radius + sim.particles[1].radius
        #expect(dist >= minDist * 0.95, "Particles should separate (dist=\(dist), minDist=\(minDist))")
    }

    // MARK: - Flip Transform

    @Test func flipTransformMirrorsYZ() {
        let sim = GranularSimulation(count: 1, particleRadius: 0.02)
        sim.particles[0] = SimParticle(
            position: SIMD3<Float>(0.05, -0.3, 0.02),
            velocity: SIMD3<Float>(0.1, -0.5, 0.3),
            radius: 0.02
        )
        let prePos = sim.particles[0].position
        let preVel = sim.particles[0].velocity

        sim.snapAfterFlip()

        let postPos = sim.particles[0].position
        let postVel = sim.particles[0].velocity

        // x unchanged, y and z negated
        #expect(abs(postPos.x - prePos.x) < 0.001)
        #expect(abs(postPos.y - (-prePos.y)) < 0.001)
        #expect(abs(postPos.z - (-prePos.z)) < 0.001)
        #expect(abs(postVel.x - preVel.x) < 0.001)
        #expect(abs(postVel.y - (-preVel.y)) < 0.001)
        #expect(abs(postVel.z - (-preVel.z)) < 0.001)
    }

    // MARK: - Full Drain

    @Test func particlesDrainToLowerChamber() {
        // Spawn particles in lower chamber, flip, then run simulation
        let count = 50
        let radius = GranularSimulation.radiusForCount(count)
        let sim = GranularSimulation(count: count, particleRadius: radius)

        // All should start in lower chamber (y < 0)
        let initialLower = sim.particles.filter { $0.position.y < 0 }.count
        #expect(initialLower == count, "All particles should start in lower chamber")

        // Flip: puts them in upper chamber
        sim.snapAfterFlip()
        let afterFlipUpper = sim.particles.filter { $0.position.y > 0 }.count
        #expect(afterFlipUpper == count, "After flip, all should be in upper chamber")

        // Run simulation for enough steps to drain
        // At 60fps, 10 seconds = 600 frames
        for _ in 0..<600 {
            sim.step(dt: 1.0 / 60.0)
        }

        let finalLower = sim.particles.filter { $0.position.y < 0 }.count
        let drainPercent = Float(finalLower) / Float(count) * 100
        #expect(drainPercent > 80, "At least 80% should drain to lower chamber (got \(drainPercent)%)")
    }

    // MARK: - Settling

    @Test func particlesSettleToRest() {
        let count = 50
        let radius = GranularSimulation.radiusForCount(count)
        let sim = GranularSimulation(count: count, particleRadius: radius)

        // Run long enough for particles to settle
        for _ in 0..<300 {
            sim.step(dt: 1.0 / 60.0)
        }

        let avgSpeed = sim.particles.reduce(Float(0)) { $0 + simd_length($1.velocity) } / Float(count)
        #expect(avgSpeed < 0.05, "Particles should settle to near-rest (avgSpeed=\(avgSpeed))")
    }

    // MARK: - Spawn Packing

    @Test func spawnPackingStaysInLowerChamber() {
        // Test the exact scenario: 10k particles at size 1.3
        let count = 10000
        let radius = GranularSimulation.radiusForCount(count, sizeMultiplier: 1.3)
        let positions = GranularSimulation.packedPositions(count: count, particleRadius: radius)

        #expect(positions.count == count, "Should return exactly \(count) positions (got \(positions.count))")

        let upperCount = positions.filter { $0.y > 0 }.count
        #expect(upperCount == 0, "No particles should spawn in upper chamber (got \(upperCount))")

        let maxY = positions.map { $0.y }.max() ?? 0
        #expect(maxY < -0.04, "Highest particle should be well below neck (maxY=\(maxY))")

        // Check no overlaps worse than 50% of diameter
        let minSep = radius * 0.5
        var badOverlaps = 0
        // Sample check: first 500 vs all others (full O(N²) would be slow)
        for i in 0..<min(500, count) {
            for j in (i+1)..<min(500, count) {
                let dist = simd_length(positions[i] - positions[j])
                if dist < minSep {
                    badOverlaps += 1
                }
            }
        }
        #expect(badOverlaps < 50, "Too many severe overlaps in spawn positions (\(badOverlaps))")
    }

    @Test func spawnPackingVariousSizes() {
        // Test spawn packing at multiple size multipliers
        for size: Float in [0.5, 1.0, 1.3, 1.5] {
            let count = 5000
            let radius = GranularSimulation.radiusForCount(count, sizeMultiplier: size)
            let positions = GranularSimulation.packedPositions(count: count, particleRadius: radius)

            #expect(positions.count == count, "Size \(size): Should return \(count) positions (got \(positions.count))")

            let upperCount = positions.filter { $0.y > 0 }.count
            #expect(upperCount == 0, "Size \(size): No particles in upper chamber (got \(upperCount))")
        }
    }

    // MARK: - Spawn Top Layer Flatness

    @Test func spawnTopLayerIsFlat() {
        // At various counts and sizes, the top layer of spawned particles
        // should be roughly the same height — no outliers sticking up.
        let configs: [(count: Int, size: Float)] = [
            (5000, 1.0), (5000, 1.3), (10000, 1.0), (10000, 1.3)
        ]
        for config in configs {
            let radius = GranularSimulation.radiusForCount(config.count, sizeMultiplier: config.size)
            let positions = GranularSimulation.packedPositions(count: config.count, particleRadius: radius)
            let ys = positions.map { $0.y }.sorted()

            // Top 5% of particles by Y
            let top5Index = Int(Float(ys.count) * 0.95)
            let y95 = ys[top5Index]
            let yMax = ys.last!

            // The spread of the top 5% should be within a few particle diameters
            let spread = yMax - y95
            let tolerance = radius * 6.0  // 3 particle diameters
            #expect(spread < tolerance,
                    "Count \(config.count) size \(config.size): top layer spread \(spread) > tolerance \(tolerance) (y95=\(y95), yMax=\(yMax), radius=\(radius))")
        }
    }

    // MARK: - Wall Containment

    @Test func particlesStayInsideGlass() {
        let count = 50
        let radius = GranularSimulation.radiusForCount(count)
        let sim = GranularSimulation(count: count, particleRadius: radius)

        // Run some physics
        for _ in 0..<120 {
            sim.step(dt: 1.0 / 60.0)
        }

        for (i, p) in sim.particles.enumerated() {
            let radial = sqrt(p.position.x * p.position.x + p.position.z * p.position.z)
            let glassR = SandGeometry.innerRadiusAt(y: p.position.y)
            #expect(radial < glassR + 0.01,
                    "Particle \(i) should be inside glass (radial=\(radial), glassR=\(glassR))")
            #expect(p.position.y - p.radius >= -0.50,
                    "Particle \(i) should be above floor")
            #expect(p.position.y + p.radius <= 0.50,
                    "Particle \(i) should be below ceiling")
        }
    }
}
