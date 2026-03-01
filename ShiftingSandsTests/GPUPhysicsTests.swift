import Testing
import Foundation
import Metal
@testable import ShiftingSands

struct GPUPhysicsTests {

    /// Helper: create a MetalPhysicsEngine or skip if Metal unavailable (e.g. CI)
    private func makeEngine(count: Int, radius: Float) throws -> MetalPhysicsEngine {
        guard let engine = MetalPhysicsEngine(count: count, particleRadius: radius) else {
            // withKnownIssue would be ideal but skip is simpler for CI
            throw MetalUnavailableError()
        }
        return engine
    }

    struct MetalUnavailableError: Error {}

    // MARK: - Gravity

    @Test func gravityMovesParticleDown() throws {
        let engine = try makeEngine(count: 1, radius: 0.02)
        // Place particle in mid-air
        let ptr = engine.currentPositionBuffer.contents().bindMemory(to: GPUParticle.self, capacity: 1)
        ptr[0] = GPUParticle(
            positionAndRadius: SIMD4<Float>(0, -0.2, 0, 0.02),
            velocityAndPad: SIMD4<Float>(0, 0, 0, 0)
        )
        let startY: Float = -0.2

        engine.step(dt: 1.0 / 60.0)

        let particles = engine.readPositions()
        #expect(particles[0].positionAndRadius.y < startY, "Particle should fall under gravity")
    }

    // MARK: - Floor Containment

    @Test func particleStaysAboveFloor() throws {
        let engine = try makeEngine(count: 1, radius: 0.02)
        let ptr = engine.currentPositionBuffer.contents().bindMemory(to: GPUParticle.self, capacity: 1)
        ptr[0] = GPUParticle(
            positionAndRadius: SIMD4<Float>(0, -0.46, 0, 0.02),
            velocityAndPad: SIMD4<Float>(0, -1.0, 0, 0)
        )

        for _ in 0..<100 {
            engine.step(dt: 1.0 / 60.0)
        }

        let particles = engine.readPositions()
        let minY = particles[0].positionAndRadius.y - particles[0].positionAndRadius.w
        #expect(minY >= -0.49, "Particle should not penetrate floor (y-r=\(minY))")
    }

    // MARK: - Flip Transform

    @Test func flipTransformMirrorsYZ() throws {
        let engine = try makeEngine(count: 1, radius: 0.02)
        let ptr = engine.currentPositionBuffer.contents().bindMemory(to: GPUParticle.self, capacity: 1)
        ptr[0] = GPUParticle(
            positionAndRadius: SIMD4<Float>(0.05, -0.3, 0.02, 0.02),
            velocityAndPad: SIMD4<Float>(0.1, -0.5, 0.3, 0)
        )

        engine.snapAfterFlip()

        let particles = engine.readPositions()
        let pos = particles[0].positionAndRadius
        let vel = particles[0].velocityAndPad

        #expect(abs(pos.x - 0.05) < 0.001)
        #expect(abs(pos.y - 0.3) < 0.001)   // -(-0.3) = 0.3
        #expect(abs(pos.z - (-0.02)) < 0.001) // -(0.02) = -0.02
        #expect(abs(vel.x - 0.1) < 0.001)
        #expect(abs(vel.y - 0.5) < 0.001)   // -(-0.5) = 0.5
        #expect(abs(vel.z - (-0.3)) < 0.001)  // -(0.3) = -0.3
        #expect(vel.w == 0.0, "Sleep counter should reset after flip")
    }

    // MARK: - Full Drain

    @Test func particlesDrainToLowerChamber() throws {
        let count = 100
        let radius = GranularSimulation.radiusForCount(count)
        let engine = try makeEngine(count: count, radius: radius)

        // Verify all start in lower chamber
        var particles = engine.readPositions()
        let initialLower = particles.filter { $0.positionAndRadius.y < 0 }.count
        #expect(initialLower == count, "All particles should start in lower chamber")

        // Flip
        engine.snapAfterFlip()
        particles = engine.readPositions()
        let afterFlipUpper = particles.filter { $0.positionAndRadius.y > 0 }.count
        #expect(afterFlipUpper == count, "After flip, all should be in upper chamber")

        // Run simulation for 10 seconds
        for _ in 0..<600 {
            engine.step(dt: 1.0 / 60.0)
        }

        particles = engine.readPositions()
        let finalLower = particles.filter { $0.positionAndRadius.y < 0 }.count
        let drainPercent = Float(finalLower) / Float(count) * 100
        #expect(drainPercent > 80, "At least 80% should drain (got \(drainPercent)%)")
    }

    // MARK: - Sleep Wake on Support Loss

    @Test func sleepingParticleWakesWhenSupportRemoved() throws {
        // Place two particles: A resting on B in the lower chamber
        let radius: Float = 0.02
        let engine = try makeEngine(count: 2, radius: radius)
        let ptr = engine.currentPositionBuffer.contents().bindMemory(to: GPUParticle.self, capacity: 2)

        // B sits on the floor, A sits directly on top of B
        let floorY: Float = -0.48 + radius
        ptr[0] = GPUParticle(  // A: on top of B
            positionAndRadius: SIMD4<Float>(0, floorY + radius * 2.0, 0, radius),
            velocityAndPad: SIMD4<Float>(0, 0, 0, 0)
        )
        ptr[1] = GPUParticle(  // B: on floor
            positionAndRadius: SIMD4<Float>(0, floorY, 0, radius),
            velocityAndPad: SIMD4<Float>(0, 0, 0, 0)
        )

        // Run until both particles are deep-sleeping (counter > 30)
        for _ in 0..<300 {
            engine.step(dt: 1.0 / 60.0)
        }
        var particles = engine.readPositions()
        let sleepA = particles[0].velocityAndPad.w
        #expect(sleepA > 15, "Particle A should be sleeping (counter=\(sleepA))")

        let posABefore = particles[0].positionAndRadius.y

        // Now remove support: move B far away
        let ptrNow = engine.currentPositionBuffer.contents().bindMemory(to: GPUParticle.self, capacity: 2)
        ptrNow[1].positionAndRadius = SIMD4<Float>(0, -0.2, 0.3, radius)  // far away
        ptrNow[1].velocityAndPad = SIMD4<Float>(0, 0, 0, 0)  // reset sleep so it doesn't interfere

        // Run a few more frames — A should wake up and fall
        for _ in 0..<60 {
            engine.step(dt: 1.0 / 60.0)
        }

        particles = engine.readPositions()
        let posAAfter = particles[0].positionAndRadius.y
        #expect(posAAfter < posABefore - radius,
                "Sleeping particle should fall after support removed (before=\(posABefore), after=\(posAAfter))")
    }

    // MARK: - Settling (Sleep System)

    @Test func particlesSettleToRest() throws {
        let count = 100
        let radius = GranularSimulation.radiusForCount(count)
        let engine = try makeEngine(count: count, radius: radius)

        // Run for 5 seconds to let particles settle
        for _ in 0..<300 {
            engine.step(dt: 1.0 / 60.0)
        }

        let particles = engine.readPositions()
        let avgSpeed = particles.reduce(Float(0)) { total, p in
            let v = p.velocityAndPad
            return total + sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        } / Float(count)

        #expect(avgSpeed < 0.05, "Particles should settle (avgSpeed=\(avgSpeed))")

        // Check sleep counters — most should be sleeping
        let sleeping = particles.filter { $0.velocityAndPad.w > 15 }.count
        let sleepPercent = Float(sleeping) / Float(count) * 100
        #expect(sleepPercent > 50, "Most particles should be sleeping (got \(sleepPercent)%)")
    }
}
