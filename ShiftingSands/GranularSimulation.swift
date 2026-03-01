import simd

struct SimParticle {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var radius: Float
}

class GranularSimulation {

    var particles: [SimParticle] = []

    // Physics configuration
    var gravity: Float = 1.0
    var damping: Float = 0.05
    var restitution: Float = 0.02
    var friction: Float = 0.6

    // Neck friction — extra damping near the constriction, scaled by duration
    var neckDamping: Float = 0.0
    let neckHalfHeight: Float = 0.10

    /// Adaptive substeps — fewer for large particle counts to maintain frame rate
    var substeps: Int {
        let n = particles.count
        if n > 1000 { return 2 }
        if n > 500 { return 3 }
        return 4
    }

    // Hourglass bounds (matches HourglassScene constants)
    let chamberBottom: Float = -0.48
    let chamberTop: Float = 0.48

    // Container rotation — updated per frame from presentation node
    var containerEulerX: Float = 0.0

    // MARK: - Initialization

    init(count: Int, particleRadius: Float) {
        let positions = GranularSimulation.packedPositions(count: count, particleRadius: particleRadius)
        particles = positions.map { pos in
            SimParticle(position: pos, velocity: .zero, radius: particleRadius)
        }
    }

    // MARK: - Packed Spawning

    /// Generate hex close-packed positions filling the lower chamber from bottom up.
    /// Shared by both CPU and GPU engines.
    /// Particles are tightly packed so they start very close to their resting state.
    static func packedPositions(count: Int, particleRadius: Float) -> [SIMD3<Float>] {
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(count)

        // Tight packing: reduce spacing slightly so particles nestle together
        let spacing = particleRadius * 2.0
        let vertSpacing = spacing * 0.866  // hex close-pack vertical gap
        let chamberBottom: Float = -0.48
        let maxY: Float = -0.10  // prefer lower half; hex lattice stops early at low counts, extends here for high counts

        var y = chamberBottom + particleRadius
        var layer = 0

        while positions.count < count && y < maxY {
            let glassR = SandGeometry.innerRadiusAt(y: y) - particleRadius - 0.003
            guard glassR > particleRadius else {
                y += vertSpacing
                layer += 1
                continue
            }

            // Offset alternate layers for hex packing
            let xOffset: Float = (layer % 2 == 0) ? 0 : spacing * 0.5

            let nSteps = Int(ceil(glassR / spacing))
            for ix in -nSteps...nSteps {
                for iz in -nSteps...nSteps {
                    guard positions.count < count else { break }
                    let x = Float(ix) * spacing + xOffset
                    let z = Float(iz) * spacing
                    let r = sqrt(x * x + z * z)
                    if r < glassR {
                        positions.append(SIMD3<Float>(x, y, z))
                    }
                }
                guard positions.count < count else { break }
            }

            y += vertSpacing
            layer += 1
        }

        // If we can't fit all particles in the lower chamber hex lattice,
        // place remaining in the widest part of the lower chamber where
        // there's room for them to settle via physics.
        // Never place near the neck — particles placed there get stuck.
        if positions.count < count {
            let bulgeMinY = chamberBottom + particleRadius
            let bulgeMaxY: Float = -0.10  // stay well below neck
            while positions.count < count {
                let ry = Float.random(in: bulgeMinY...bulgeMaxY)
                let rGlassR = max(SandGeometry.innerRadiusAt(y: ry) - particleRadius - 0.003, 0.001)
                let rr = Float.random(in: 0...rGlassR)
                let rAngle = Float.random(in: 0...(2 * .pi))
                positions.append(SIMD3<Float>(rr * cos(rAngle), ry, rr * sin(rAngle)))
            }
        }

        return positions
    }

    // MARK: - Physics Step

    func step(dt: Float) {
        guard !particles.isEmpty else { return }

        let subDt = dt / Float(substeps)
        let localGravity = computeLocalGravity()

        for _ in 0..<substeps {
            // 1. Apply gravity
            for i in particles.indices {
                particles[i].velocity += localGravity * subDt
            }

            // 2. Update positions
            for i in particles.indices {
                particles[i].position += particles[i].velocity * subDt
            }

            // 3. Wall collision (glass profile)
            resolveWallCollisions()

            // 4. Floor/ceiling bounds
            resolveFloorCeiling()

            // 5. Sphere-sphere collision
            resolveSphereCollisions()

            // 6. Neck friction zone — extra damping near the constriction
            if neckDamping > 0 {
                for i in particles.indices {
                    let neckDist = abs(particles[i].position.y)
                    if neckDist < neckHalfHeight {
                        let neckFactor = 1.0 - neckDist / neckHalfHeight
                        let damp = max(Float(0), 1.0 - neckFactor * neckDamping * subDt)
                        particles[i].velocity *= damp
                    }
                }
            }

            // 7. Velocity-dependent damping: light at high speed (free flow),
            //    heavy at low speed (fast settling). Blend between the two.
            let flowDamp = powf(Float(0.92), subDt)   // gentle — preserves natural flow
            let settleDamp = powf(Float(0.05), subDt)  // aggressive — kills residual jitter
            let speedThreshold: Float = 0.15
            for i in particles.indices {
                let speed = simd_length(particles[i].velocity)
                let t = min(speed / speedThreshold, 1.0)  // 0 = at rest, 1 = flowing
                let dampFactor = settleDamp + (flowDamp - settleDamp) * t
                particles[i].velocity *= dampFactor
            }
        }
    }

    // MARK: - Gravity

    /// Transform world gravity (0, -g, 0) into hourglassContainer local space.
    /// Container rotates around X axis by containerEulerX during flip.
    private func computeLocalGravity() -> SIMD3<Float> {
        let theta = containerEulerX
        return SIMD3<Float>(
            0,
            -gravity * cos(theta),
            gravity * sin(theta)
        )
    }

    // MARK: - Collision Detection

    private func resolveWallCollisions() {
        for i in particles.indices {
            let p = particles[i]
            let r = p.radius

            // Radial distance from Y axis
            let radial = sqrt(p.position.x * p.position.x + p.position.z * p.position.z)
            let glassR = SandGeometry.innerRadiusAt(y: p.position.y) - 0.003
            let maxR = glassR - r

            if maxR < 0.001 {
                // Very narrow section (near top/bottom tips) — push toward centre
                if radial > 0.001 {
                    let scale = 0.001 / radial
                    particles[i].position.x *= scale
                    particles[i].position.z *= scale
                    particles[i].velocity.x = 0
                    particles[i].velocity.z = 0
                }
                continue
            }

            if radial > maxR && radial > 0.001 {
                // Push particle inward
                let scale = maxR / radial
                particles[i].position.x *= scale
                particles[i].position.z *= scale

                // Reflect radial velocity component
                let nx = p.position.x / radial
                let nz = p.position.z / radial
                let radialVel = particles[i].velocity.x * nx + particles[i].velocity.z * nz

                if radialVel > 0 {  // moving outward
                    particles[i].velocity.x -= (1 + restitution) * radialVel * nx
                    particles[i].velocity.z -= (1 + restitution) * radialVel * nz

                    // Friction on tangential component
                    let tangentVelX = particles[i].velocity.x - (particles[i].velocity.x * nx + particles[i].velocity.z * nz) * nx
                    let tangentVelZ = particles[i].velocity.z - (particles[i].velocity.x * nx + particles[i].velocity.z * nz) * nz
                    particles[i].velocity.x -= tangentVelX * friction
                    particles[i].velocity.z -= tangentVelZ * friction
                }
            }
        }
    }

    private func resolveFloorCeiling() {
        for i in particles.indices {
            let r = particles[i].radius

            // Bottom
            if particles[i].position.y - r < chamberBottom {
                particles[i].position.y = chamberBottom + r
                if particles[i].velocity.y < 0 {
                    particles[i].velocity.y *= -restitution
                }
                // Friction
                particles[i].velocity.x *= (1 - friction)
                particles[i].velocity.z *= (1 - friction)
            }

            // Top
            if particles[i].position.y + r > chamberTop {
                particles[i].position.y = chamberTop - r
                if particles[i].velocity.y > 0 {
                    particles[i].velocity.y *= -restitution
                }
                particles[i].velocity.x *= (1 - friction)
                particles[i].velocity.z *= (1 - friction)
            }
        }
    }

    private func resolveSphereCollisions() {
        let n = particles.count
        for i in 0..<n {
            for j in (i + 1)..<n {
                let delta = particles[i].position - particles[j].position
                let dist = simd_length(delta)
                let minDist = particles[i].radius + particles[j].radius

                guard dist < minDist && dist > 0.0001 else { continue }

                let normal = delta / dist
                let overlap = minDist - dist

                // Push apart equally
                particles[i].position += normal * (overlap * 0.5)
                particles[j].position -= normal * (overlap * 0.5)

                // Velocity exchange along collision normal
                let relVel = particles[i].velocity - particles[j].velocity
                let relVelNormal = simd_dot(relVel, normal)

                guard relVelNormal < 0 else { continue }  // already separating

                let impulse = -(1 + restitution) * relVelNormal * 0.5
                particles[i].velocity += normal * impulse
                particles[j].velocity -= normal * impulse
            }
        }
    }

    // MARK: - Flip Support

    /// Transform particle positions and velocities after the container snaps
    /// from eulerAngles.x = π back to 0. Rotation by π around X:
    /// (x, y, z) → (x, -y, -z)
    func snapAfterFlip() {
        for i in particles.indices {
            particles[i].position.y = -particles[i].position.y
            particles[i].position.z = -particles[i].position.z
            particles[i].velocity.y = -particles[i].velocity.y
            particles[i].velocity.z = -particles[i].velocity.z
        }
        containerEulerX = 0
    }

    /// Reinitialize all particles in the lower chamber
    func resetToBottom(count: Int, particleRadius: Float) {
        let positions = GranularSimulation.packedPositions(count: count, particleRadius: particleRadius)
        particles = positions.map { pos in
            SimParticle(position: pos, velocity: .zero, radius: particleRadius)
        }
    }

    // MARK: - Helpers

    /// Compute particle radius so the packed pile fills ~25% of the hourglass
    /// (roughly half the lower chamber) regardless of particle count.
    ///
    /// Base formula: r ∝ N^(-1/3) keeps total sphere volume constant.
    /// Correction: at higher counts, smaller particles leave more clearance
    /// from the glass walls, so each layer holds proportionally more particles
    /// and the pile ends up shorter. The correction scales radius up slightly
    /// to compensate, keeping visual fill height constant across all counts.
    /// Anchored to 250 particles (the CPU mode reference that "looks right").
    static func radiusForCount(_ count: Int, sizeMultiplier: Float = 1.0) -> Float {
        let baseR: Float = 0.030 * pow(Float(100) / Float(max(count, 1)), 1.0 / 3.0)
        // Effective packing radius = glass inner radius at chamber centre minus clearance minus particle radius
        let nominalGlassR: Float = 0.147  // innerRadius - wallClearance at chamber bulge (~y=-0.25)
        let effR = nominalGlassR - baseR
        // Reference: 250 particles where visual fill is calibrated
        let refBaseR: Float = 0.030 * pow(Float(100) / Float(250), 1.0 / 3.0)  // ≈ 0.0221
        let refEffR = nominalGlassR - refBaseR  // ≈ 0.125
        guard effR > 0.01 else { return baseR * sizeMultiplier }
        return baseR * pow(effR / refEffR, 2.0 / 3.0) * sizeMultiplier
    }
}
