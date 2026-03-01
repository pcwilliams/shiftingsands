import SceneKit

struct ProfilePoint {
    let radius: Float
    let height: Float
}

enum SandGeometry {

    // Control points for hourglass profile (bottom to top)
    // These are interpolated with Catmull-Rom splines for smooth curves
    private static let controlPoints: [ProfilePoint] = [
        ProfilePoint(radius: 0.00, height: -0.50),
        ProfilePoint(radius: 0.16, height: -0.50),
        ProfilePoint(radius: 0.22, height: -0.42),
        ProfilePoint(radius: 0.22, height: -0.20),
        ProfilePoint(radius: 0.15, height: -0.08),
        ProfilePoint(radius: 0.04, height:  0.00),  // neck
        ProfilePoint(radius: 0.15, height:  0.08),
        ProfilePoint(radius: 0.22, height:  0.20),
        ProfilePoint(radius: 0.22, height:  0.42),
        ProfilePoint(radius: 0.16, height:  0.50),
        ProfilePoint(radius: 0.00, height:  0.50),
    ]

    static let wallThickness: Float = 0.008

    // Smooth outer profile generated via Catmull-Rom interpolation (default neck)
    static let outerProfile: [ProfilePoint] = {
        interpolateProfile(controlPoints, subdivisions: 8)
    }()

    static let innerProfile: [ProfilePoint] = {
        outerProfile.map { point in
            let r = max(point.radius - wallThickness, 0.0)
            return ProfilePoint(radius: r, height: point.height)
        }
    }()

    // Active profiles — updated when neck radius changes for particle size
    private(set) static var activeOuterProfile: [ProfilePoint] = outerProfile
    private(set) static var activeInnerProfile: [ProfilePoint] = innerProfile

    /// Rebuild glass profiles with a custom neck radius so exactly one particle fits through
    static func setNeckRadius(_ neckRadius: Float) {
        // Neck shoulder radius is proportional to neck but much narrower than the bulb,
        // creating a steep funnel that forces single-file flow and particle backup
        let shoulderR = max(neckRadius * 1.8, neckRadius + 0.01)
        let points: [ProfilePoint] = [
            ProfilePoint(radius: 0.00, height: -0.50),
            ProfilePoint(radius: 0.16, height: -0.50),
            ProfilePoint(radius: 0.22, height: -0.42),
            ProfilePoint(radius: 0.22, height: -0.20),
            ProfilePoint(radius: shoulderR, height: -0.04),
            ProfilePoint(radius: neckRadius, height:  0.00),
            ProfilePoint(radius: shoulderR, height:  0.04),
            ProfilePoint(radius: 0.22, height:  0.20),
            ProfilePoint(radius: 0.22, height:  0.42),
            ProfilePoint(radius: 0.16, height:  0.50),
            ProfilePoint(radius: 0.00, height:  0.50),
        ]
        activeOuterProfile = interpolateProfile(points, subdivisions: 8)
        activeInnerProfile = activeOuterProfile.map { point in
            ProfilePoint(radius: max(point.radius - wallThickness, 0.0), height: point.height)
        }
    }

    // MARK: - Catmull-Rom Spline Interpolation

    /// Interpolate between control points using Catmull-Rom splines
    private static func interpolateProfile(
        _ points: [ProfilePoint],
        subdivisions: Int
    ) -> [ProfilePoint] {
        guard points.count >= 4 else { return points }
        var result: [ProfilePoint] = []

        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[min(i + 1, points.count - 1)]
            let p3 = points[min(i + 2, points.count - 1)]

            let steps = (i == 0 || i == points.count - 2) ? 1 : subdivisions
            for s in 0..<steps {
                let t = Float(s) / Float(steps)
                let r = catmullRom(p0.radius, p1.radius, p2.radius, p3.radius, t)
                let h = catmullRom(p0.height, p1.height, p2.height, p3.height, t)
                result.append(ProfilePoint(radius: max(r, 0), height: h))
            }
        }
        // Add final point
        result.append(points.last!)
        return result
    }

    /// Catmull-Rom spline interpolation for a single value
    private static func catmullRom(
        _ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float
    ) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1) +
            (-p0 + p2) * t +
            (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
            (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }

    // MARK: - Surface of Revolution

    /// Create a surface-of-revolution geometry from a 2D profile curve
    static func createRevolutionSurface(
        profile: [ProfilePoint],
        segments: Int = 48,
        flipNormals: Bool = false
    ) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var texCoords: [CGPoint] = []
        var indices: [UInt32] = []

        let angleStep = Float.pi * 2.0 / Float(segments)
        let ringCount = segments + 1

        for (pIdx, point) in profile.enumerated() {
            // Compute profile-plane normal (perpendicular to tangent along profile)
            let tangent: (dr: Float, dh: Float)
            if pIdx == 0 {
                tangent = (profile[1].radius - profile[0].radius,
                           profile[1].height - profile[0].height)
            } else if pIdx == profile.count - 1 {
                tangent = (profile[pIdx].radius - profile[pIdx - 1].radius,
                           profile[pIdx].height - profile[pIdx - 1].height)
            } else {
                tangent = (profile[pIdx + 1].radius - profile[pIdx - 1].radius,
                           profile[pIdx + 1].height - profile[pIdx - 1].height)
            }
            let len = sqrt(tangent.dr * tangent.dr + tangent.dh * tangent.dh)
            let profileNormalRadial: Float
            let profileNormalY: Float
            if len > 0.0001 {
                profileNormalRadial = tangent.dh / len
                profileNormalY = -tangent.dr / len
            } else {
                profileNormalRadial = 1.0
                profileNormalY = 0.0
            }

            let v = Float(pIdx) / Float(profile.count - 1)

            for seg in 0...segments {
                let angle = Float(seg) * angleStep
                let cosA = cos(angle)
                let sinA = sin(angle)

                vertices.append(SCNVector3(
                    point.radius * cosA,
                    point.height,
                    point.radius * sinA
                ))

                let dir: Float = flipNormals ? -1.0 : 1.0
                normals.append(SCNVector3(
                    profileNormalRadial * cosA * dir,
                    profileNormalY * dir,
                    profileNormalRadial * sinA * dir
                ))

                texCoords.append(CGPoint(
                    x: CGFloat(Float(seg) / Float(segments)),
                    y: CGFloat(v)
                ))
            }
        }

        for pIdx in 0..<(profile.count - 1) {
            for seg in 0..<segments {
                let current = UInt32(pIdx * ringCount + seg)
                let next = current + 1
                let below = current + UInt32(ringCount)
                let belowNext = below + 1

                if flipNormals {
                    indices.append(contentsOf: [current, next, below])
                    indices.append(contentsOf: [next, belowNext, below])
                } else {
                    indices.append(contentsOf: [current, below, next])
                    indices.append(contentsOf: [next, below, belowNext])
                }
            }
        }

        let positionSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let texCoordSource = SCNGeometrySource(textureCoordinates: texCoords)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

        return SCNGeometry(
            sources: [positionSource, normalSource, texCoordSource],
            elements: [element]
        )
    }

    // MARK: - Sand Pile Cone

    /// Create a cone mesh for the sand pile (grows upward as sand accumulates)
    static func createPileCone(
        baseRadius: Float,
        height: Float,
        segments: Int = 36
    ) -> SCNGeometry {
        guard height > 0.0001 && baseRadius > 0.0001 else {
            // Degenerate: return a flat disc
            return SCNPlane(width: 0.001, height: 0.001)
        }

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []

        let angleStep = Float.pi * 2.0 / Float(segments)
        let slopeAngle = atan2(height, baseRadius)
        let normalY = cos(slopeAngle)
        let normalR = sin(slopeAngle)

        // Apex
        vertices.append(SCNVector3(0, height, 0))
        normals.append(SCNVector3(0, 1, 0))

        // Rings from apex to base
        let rings = 8
        for ring in 0...rings {
            let t = Float(ring) / Float(rings)
            let r = baseRadius * t
            let y = height * (1.0 - t)
            for seg in 0...segments {
                let angle = Float(seg) * angleStep
                vertices.append(SCNVector3(r * cos(angle), y, r * sin(angle)))
                normals.append(SCNVector3(normalR * cos(angle), normalY, normalR * sin(angle)))
            }
        }

        // Apex to first ring
        let ringSize = segments + 1
        for seg in 0..<segments {
            indices.append(contentsOf: [0, UInt32(1 + seg), UInt32(1 + seg + 1)])
        }

        // Ring to ring
        for ring in 0..<rings {
            for seg in 0..<segments {
                let current = UInt32(1 + ring * ringSize + seg)
                let next = current + 1
                let below = current + UInt32(ringSize)
                let belowNext = below + 1
                indices.append(contentsOf: [current, below, next])
                indices.append(contentsOf: [next, below, belowNext])
            }
        }

        // Base cap
        let baseCentre = UInt32(vertices.count)
        vertices.append(SCNVector3(0, 0, 0))
        normals.append(SCNVector3(0, -1, 0))
        let lastRingStart = UInt32(1 + rings * ringSize)
        for seg in 0..<segments {
            indices.append(contentsOf: [
                baseCentre,
                lastRingStart + UInt32(seg + 1),
                lastRingStart + UInt32(seg),
            ])
        }

        let positionSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [positionSource, normalSource], elements: [element])
    }

    // MARK: - Inner Radius Lookup

    /// Returns the inner glass radius at a given Y height by interpolating the active profile
    static func innerRadiusAt(y: Float) -> Float {
        let profile = activeInnerProfile
        for i in 0..<(profile.count - 1) {
            let p0 = profile[i]
            let p1 = profile[i + 1]
            if (p0.height <= y && p1.height >= y) || (p1.height <= y && p0.height >= y) {
                if abs(p1.height - p0.height) < 0.0001 { return p0.radius }
                let t = (y - p0.height) / (p1.height - p0.height)
                return p0.radius + t * (p1.radius - p0.radius)
            }
        }
        return 0.21
    }

    // MARK: - Sand Body (Upper Chamber Fill)

    /// Create a solid sand body that fills the hourglass inner profile from topY down to bottomY.
    /// The outer wall follows the glass profile; top is open (bowl cap sits on top).
    static func createSandBody(
        topY: Float,
        bottomY: Float,
        segments: Int = 36,
        heightSteps: Int = 16
    ) -> SCNGeometry {
        guard topY > bottomY + 0.001 else {
            return SCNPlane(width: 0.001, height: 0.001)
        }

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []

        let angleStep = Float.pi * 2.0 / Float(segments)
        let ringCount = segments + 1

        // Generate rings from top to bottom, each at the inner profile radius
        for step in 0...heightSteps {
            let t = Float(step) / Float(heightSteps)
            let y = topY - t * (topY - bottomY)
            let r = innerRadiusAt(y: y) - 0.005 // slight inset so sand doesn't z-fight with glass

            for seg in 0...segments {
                let angle = Float(seg) * angleStep
                vertices.append(SCNVector3(r * cos(angle), y, r * sin(angle)))
                // Normals point inward (visible from inside — but we want outward-facing for a solid body)
                // Actually for a solid sand body viewed from outside, normals should point outward
                normals.append(SCNVector3(cos(angle), 0, sin(angle)))
            }
        }

        // Connect rings
        for step in 0..<heightSteps {
            for seg in 0..<segments {
                let current = UInt32(step * ringCount + seg)
                let next = current + 1
                let below = current + UInt32(ringCount)
                let belowNext = below + 1
                indices.append(contentsOf: [current, below, next])
                indices.append(contentsOf: [next, below, belowNext])
            }
        }

        // Bottom cap
        let capCentre = UInt32(vertices.count)
        vertices.append(SCNVector3(0, bottomY, 0))
        normals.append(SCNVector3(0, -1, 0))
        let lastRingStart = UInt32(heightSteps * ringCount)
        for seg in 0..<segments {
            indices.append(contentsOf: [
                capCentre,
                lastRingStart + UInt32(seg + 1),
                lastRingStart + UInt32(seg),
            ])
        }

        let positionSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [positionSource, normalSource], elements: [element])
    }

    // MARK: - Sand Pile with Glass-Conforming Profile

    /// Create a unified pile mesh where each ring's radius is the minimum of the
    /// cone slope (angle of repose) and the glass inner profile at that height.
    /// This produces a single continuous mesh that naturally flattens against the
    /// glass walls — no separate base/cone pieces that can separate.
    static func createPileWithSpread(
        totalHeight: Float,
        chamberBottomY: Float,
        angleOfRepose: Float,
        segments: Int = 36,
        rings: Int = 24
    ) -> SCNGeometry {
        guard totalHeight > 0.0001 else {
            return SCNPlane(width: 0.001, height: 0.001)
        }

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []

        let angleStep = Float.pi * 2.0 / Float(segments)
        let tanRepose = tan(angleOfRepose)
        let ringSize = segments + 1

        // Precompute ring radii and heights for normal calculation
        var ringRadii: [Float] = []
        var ringHeights: [Float] = []

        for ring in 0...rings {
            let t = Float(ring) / Float(rings)
            let localY = t * totalHeight
            let absoluteY = chamberBottomY + localY

            // Cone slope: apex at top, widening downward
            let coneRadius = (totalHeight - localY) / tanRepose
            // Glass inner wall constraint
            let glassRadius = innerRadiusAt(y: absoluteY) - 0.005
            let r = max(min(coneRadius, glassRadius), 0.0)

            ringRadii.append(r)
            ringHeights.append(localY)
        }

        // Generate vertices with finite-difference normals
        for ring in 0...rings {
            let r = ringRadii[ring]
            let localY = ringHeights[ring]

            // Compute surface normal from slope between adjacent rings
            let dr: Float
            let dy: Float
            if ring == 0 {
                dr = ringRadii[1] - ringRadii[0]
                dy = ringHeights[1] - ringHeights[0]
            } else if ring == rings {
                dr = ringRadii[rings] - ringRadii[rings - 1]
                dy = ringHeights[rings] - ringHeights[rings - 1]
            } else {
                dr = ringRadii[ring + 1] - ringRadii[ring - 1]
                dy = ringHeights[ring + 1] - ringHeights[ring - 1]
            }
            // Tangent along profile (bottom→top): (dr, dy). dr < 0 (narrowing upward).
            // Outward normal perpendicular to tangent: (dy, -dr)
            let len = sqrt(dr * dr + dy * dy)
            let normalR: Float
            let normalY: Float
            if len > 0.0001 {
                normalR = dy / len
                normalY = -dr / len
            } else {
                normalR = 0.0
                normalY = 1.0
            }

            for seg in 0...segments {
                let angle = Float(seg) * angleStep
                vertices.append(SCNVector3(r * cos(angle), localY, r * sin(angle)))
                normals.append(SCNVector3(normalR * cos(angle), normalY, normalR * sin(angle)))
            }
        }

        // Connect rings
        for ring in 0..<rings {
            for seg in 0..<segments {
                let current = UInt32(ring * ringSize + seg)
                let next = current + 1
                let above = current + UInt32(ringSize)
                let aboveNext = above + 1
                indices.append(contentsOf: [current, above, next])
                indices.append(contentsOf: [next, above, aboveNext])
            }
        }

        // Bottom cap
        let baseCentre = UInt32(vertices.count)
        vertices.append(SCNVector3(0, 0, 0))
        normals.append(SCNVector3(0, -1, 0))
        for seg in 0..<segments {
            indices.append(contentsOf: [baseCentre, UInt32(seg + 1), UInt32(seg)])
        }

        let positionSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [positionSource, normalSource], elements: [element])
    }

    // MARK: - Concave Sand Bowl (Upper Chamber)

    /// Create a concave bowl/funnel shape for the upper sand surface
    /// As sand drains, the centre dips lower (funnel toward the neck)
    static func createConcaveBowl(
        outerRadius: Float,
        rimHeight: Float,
        centreDepth: Float,
        segments: Int = 36,
        rings: Int = 10
    ) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [UInt32] = []

        let angleStep = Float.pi * 2.0 / Float(segments)

        // Generate rings from centre outward
        for ring in 0...rings {
            let t = Float(ring) / Float(rings)
            let r = outerRadius * t
            // Parabolic curve: centre is depressed, edges are at rim height
            let y = rimHeight - centreDepth * (1.0 - t * t)

            for seg in 0...segments {
                let angle = Float(seg) * angleStep
                vertices.append(SCNVector3(r * cos(angle), y, r * sin(angle)))

                // Normal: approximate from the slope of the parabola
                // dy/dr = centreDepth * 2 * t / outerRadius
                let dydR = centreDepth * 2.0 * t
                let nLen = sqrt(dydR * dydR + 1.0)
                let ny: Float = 1.0 / nLen
                let nr: Float = dydR / nLen
                normals.append(SCNVector3(
                    nr * cos(angle),
                    ny,
                    nr * sin(angle)
                ))
            }
        }

        // Connect rings with triangles
        let ringSize = segments + 1
        for ring in 0..<rings {
            for seg in 0..<segments {
                let current = UInt32(ring * ringSize + seg)
                let next = current + 1
                let below = current + UInt32(ringSize)
                let belowNext = below + 1
                indices.append(contentsOf: [current, below, next])
                indices.append(contentsOf: [next, below, belowNext])
            }
        }

        // Bottom cap (closes the bowl underneath)
        let capCentre = UInt32(vertices.count)
        vertices.append(SCNVector3(0, rimHeight - centreDepth - 0.005, 0))
        normals.append(SCNVector3(0, -1, 0))
        for seg in 0..<segments {
            indices.append(contentsOf: [capCentre, UInt32(seg + 1), UInt32(seg)])
        }

        let positionSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [positionSource, normalSource], elements: [element])
    }
}
