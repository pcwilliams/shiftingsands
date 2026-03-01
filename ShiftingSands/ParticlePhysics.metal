#include <metal_stdlib>
using namespace metal;

// Must match MetalPhysicsEngine.swift GPUParticle layout
struct GPUParticle {
    float4 positionAndRadius;  // xyz = position, w = radius
    float4 velocityAndPad;     // xyz = velocity, w = sleep counter
};

struct PhysicsUniforms {
    float gravity;
    float damping;
    float restitution;
    float friction;
    float subDt;
    float containerEulerX;
    float chamberBottom;
    float chamberTop;
    uint  particleCount;
    float neckDamping;
    float neckHalfHeight;
};

// MARK: - Physics Step Kernel

kernel void physicsStep(
    device const GPUParticle* readParticles  [[buffer(0)]],
    device GPUParticle*       writeParticles [[buffer(1)]],
    device const float*       profileTable   [[buffer(2)]],
    device const PhysicsUniforms& uniforms   [[buffer(3)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid >= uniforms.particleCount) return;

    GPUParticle me = readParticles[tid];
    float3 pos = me.positionAndRadius.xyz;
    float  radius = me.positionAndRadius.w;
    float3 vel = me.velocityAndPad.xyz;
    float  sleepCounter = me.velocityAndPad.w;

    // ── Sleep system ──────────────────────────────────────────────────
    // velocityAndPad.w is a per-particle sleep counter.  When speed stays
    // below 0.02 for 15+ frames the particle is "sleeping".
    //
    // Two tiers to minimise GPU work at rest:
    //   counter 16–30  "light sleep" — O(N) wake-up check per frame
    //   counter > 30   "deep sleep"  — zero work, only wakes on flip
    //
    // This eliminates the shimmer/flicker caused by parallel collision
    // resolution reading stale snapshots (CPU converges sequentially).

    if (sleepCounter > 30.0) {
        // ── Deep sleep: staggered support verification ───────────────
        // Each particle checks once every 30 frames, offset by tid.
        // Cost: ~N/30 particles scan per frame instead of all N.
        // A hanging particle detects lost support within ~0.5 seconds.
        bool needsCheck = (((uint)(sleepCounter) % 30) == (tid % 30));
        if (!needsCheck) {
            writeParticles[tid].positionAndRadius = me.positionAndRadius;
            writeParticles[tid].velocityAndPad = float4(0.0, 0.0, 0.0,
                                                        min(sleepCounter + 1.0, 60.0));
            return;
        }
        // Our turn — verify support still exists
        // Floor counts as support — no scan needed
        bool deepHasSupport = (pos.y - radius) < (uniforms.chamberBottom + radius * 0.1);
        if (!deepHasSupport) {
            // Scan for any nearby particle (with slight tolerance for
            // floating-point gaps at exact resting distance)
            for (uint j = 0; j < uniforms.particleCount; j++) {
                if (j == tid) continue;
                float3 otherPos = readParticles[j].positionAndRadius.xyz;
                float  otherRadius = readParticles[j].positionAndRadius.w;
                float  dist = length(pos - otherPos);
                if (dist < (radius + otherRadius) * 1.05) {
                    deepHasSupport = true;
                    break;
                }
            }
        }
        if (deepHasSupport) {
            writeParticles[tid].positionAndRadius = me.positionAndRadius;
            writeParticles[tid].velocityAndPad = float4(0.0, 0.0, 0.0,
                                                        min(sleepCounter + 1.0, 60.0));
            return;
        }
        // No support — wake up, fall through to normal physics
        sleepCounter = 0.0;
    }

    if (sleepCounter > 15.0) {
        // ── Light sleep: freeze in place, check for wake-up ─────────
        // Only wake if an awake neighbor is actively approaching.
        // Support-loss detection is handled by the deep sleep staggered
        // check (within ~0.5s) — no sleepContactCount needed here.
        // Using sleepContactCount caused oscillation: particles barely
        // separated from neighbors woke every ~15 frames, creating
        // visible blur through the glass.
        bool woken = false;
        for (uint j = 0; j < uniforms.particleCount; j++) {
            if (j == tid) continue;
            float3 otherPos = readParticles[j].positionAndRadius.xyz;
            float  otherRadius = readParticles[j].positionAndRadius.w;
            float3 delta = pos - otherPos;
            float  dist = length(delta);
            float  minDist = radius + otherRadius;
            if (dist < minDist && dist > 0.0001) {
                bool otherSleeping = readParticles[j].velocityAndPad.w > 15.0;
                if (!otherSleeping) {
                    float3 normal = delta / dist;
                    float3 otherVel = readParticles[j].velocityAndPad.xyz;
                    float  relVelN = dot(vel - otherVel, normal);
                    if (relVelN < -0.05) {
                        woken = true;
                        break;
                    }
                }
            }
        }
        if (!woken) {
            writeParticles[tid].positionAndRadius = me.positionAndRadius;
            writeParticles[tid].velocityAndPad = float4(0.0, 0.0, 0.0,
                                                        min(sleepCounter + 1.0, 60.0));
            return;
        }
        // Woken up — reset counter and fall through to normal physics
        sleepCounter = 0.0;
    }

    // ── Normal physics (awake particles) ──────────────────────────────

    float subDt = uniforms.subDt;
    float gravity = uniforms.gravity;
    float restitution = uniforms.restitution;
    float friction = uniforms.friction;
    float theta = uniforms.containerEulerX;

    // 1. Apply rotated gravity
    float3 localGravity = float3(0.0,
                                 -gravity * cos(theta),
                                  gravity * sin(theta));
    vel += localGravity * subDt;

    // 2. Update position
    pos += vel * subDt;

    // 3. Wall collision (radial vs glass profile lookup table)
    float radial = sqrt(pos.x * pos.x + pos.z * pos.z);

    // Look up inner glass radius from pre-computed 256-entry table
    float yNorm = clamp((pos.y + 0.5) * 255.0, 0.0, 255.0);
    uint idx = (uint)yNorm;
    uint idx1 = min(idx + 1, 255u);
    float frac = yNorm - (float)idx;
    float glassR = mix(profileTable[idx], profileTable[idx1], frac);

    float maxR = glassR - radius;

    if (maxR < 0.001) {
        // Very narrow section — push toward centre
        if (radial > 0.001) {
            float scale = 0.001 / radial;
            pos.x *= scale;
            pos.z *= scale;
            vel.x = 0.0;
            vel.z = 0.0;
        }
    } else if (radial > maxR && radial > 0.001) {
        // Push inward
        float scale = maxR / radial;
        pos.x *= scale;
        pos.z *= scale;

        // Reflect radial velocity
        float nx = pos.x / (maxR > 0.001 ? maxR : 0.001);
        float nz = pos.z / (maxR > 0.001 ? maxR : 0.001);
        float radialVel = vel.x * nx + vel.z * nz;

        if (radialVel > 0.0) {
            vel.x -= (1.0 + restitution) * radialVel * nx;
            vel.z -= (1.0 + restitution) * radialVel * nz;

            // Tangential friction
            float dotVN = vel.x * nx + vel.z * nz;
            float tangentX = vel.x - dotVN * nx;
            float tangentZ = vel.z - dotVN * nz;
            vel.x -= tangentX * friction;
            vel.z -= tangentZ * friction;
        }
    }

    // 4. Floor/ceiling bounds with resting contact detection.
    //    After bounce, if the resulting velocity is tiny (just gravity's
    //    micro-bounce, not a real fall), zero it — the particle is resting.
    if (pos.y - radius < uniforms.chamberBottom) {
        pos.y = uniforms.chamberBottom + radius;
        if (vel.y < 0.0) {
            vel.y *= -restitution;
        }
        // Resting contact: if bounce velocity is negligible, particle is
        // sitting on the floor — zero Y to prevent gravity-bounce cycle
        if (abs(vel.y) < gravity * subDt * 2.0) {
            vel.y = 0.0;
        }
        vel.x *= (1.0 - friction);
        vel.z *= (1.0 - friction);
    }

    if (pos.y + radius > uniforms.chamberTop) {
        pos.y = uniforms.chamberTop - radius;
        if (vel.y > 0.0) {
            vel.y *= -restitution;
        }
        if (abs(vel.y) < gravity * subDt * 2.0) {
            vel.y = 0.0;
        }
        vel.x *= (1.0 - friction);
        vel.z *= (1.0 - friction);
    }

    // 5. Sphere-sphere collision (O(N) per thread, O(N²) total)
    //    Upper chamber (pos.y > 0): position correction only (no impulse).
    //    Parallel collision can't propagate forces through a packed pile
    //    (unlike sequential CPU), so velocity impulses cancel gravity and
    //    jam the pile.  Skipping impulse lets gravity drain the pile.
    //    Lower chamber: full correction + impulse for stable resting piles.
    bool inUpperChamber = (pos.y > 0.0);
    uint contactCount = 0;  // track collisions to prevent mid-air sleep

    for (uint j = 0; j < uniforms.particleCount; j++) {
        if (j == tid) continue;

        float3 otherPos = readParticles[j].positionAndRadius.xyz;
        float  otherRadius = readParticles[j].positionAndRadius.w;

        float3 delta = pos - otherPos;
        float dist = length(delta);
        float minDist = radius + otherRadius;

        if (dist < minDist && dist > 0.0001) {
            contactCount++;
            float3 normal = delta / dist;
            float overlap = minDist - dist;

            // Push apart — position correction
            pos += normal * (overlap * 0.25);

            // Velocity impulse — only in lower chamber
            // Upper chamber: skip impulse so gravity dominates pile drainage
            if (!inUpperChamber) {
                float3 otherVel = readParticles[j].velocityAndPad.xyz;
                float3 relVel = vel - otherVel;
                float relVelNormal = dot(relVel, normal);

                if (relVelNormal < 0.0) {
                    float impulse = -(1.0 + restitution) * relVelNormal * 0.25;
                    vel += normal * impulse;
                }
            }
        }
    }

    // 6. Neck friction zone — extra damping near the constriction
    if (uniforms.neckDamping > 0.0 && uniforms.neckHalfHeight > 0.0) {
        float neckDist = abs(pos.y);
        if (neckDist < uniforms.neckHalfHeight) {
            float neckFactor = 1.0 - neckDist / uniforms.neckHalfHeight;
            float damp = max(0.0, 1.0 - neckFactor * uniforms.neckDamping * subDt);
            vel *= damp;
        }
    }

    // 7. Velocity-dependent damping
    //    Lower chamber: blend between flow (gentle) and settle (aggressive)
    //    Upper chamber: flow damping only — must not kill gravity
    float flowDamp = pow(0.92, subDt);    // gentle — preserves natural flow
    float speed = length(vel);
    if (inUpperChamber) {
        vel *= flowDamp;
    } else {
        float settleDamp = pow(0.05, subDt);  // aggressive — kills residual jitter
        float t = min(speed / 0.15, 1.0);     // 0 = at rest, 1 = flowing
        float dampFactor = settleDamp + (flowDamp - settleDamp) * t;
        vel *= dampFactor;
    }

    // 8. Velocity cutoff: snap to zero below threshold (lower chamber only)
    //    Upper chamber must accumulate tiny gravity increments to drain.
    //    Only apply when particle has contacts (resting on something).
    //    Free-falling particles (zero contacts) must never be frozen.
    bool hasSupport = (contactCount > 0);
    if (!inUpperChamber && hasSupport && length(vel) < 0.01) {
        vel = float3(0.0);
    }

    // 9. Update sleep counter
    //    Only allow sleeping in the LOWER chamber AND when the particle has
    //    contacts (resting on pile or floor).  Upper-chamber particles must
    //    stay fully awake.  Free-falling particles must never sleep.
    if (pos.y >= 0.0) {
        // Upper chamber: always awake — must drain
        sleepCounter = 0.0;
    } else if (hasSupport && length(vel) < 0.08) {
        // Lower chamber, in contact: generous threshold catches surface oscillation
        sleepCounter = min(sleepCounter + 1.0, 60.0);
    } else {
        sleepCounter = 0.0;
    }

    // Write to output buffer (w = sleep counter, persists across frames)
    writeParticles[tid].positionAndRadius = float4(pos, radius);
    writeParticles[tid].velocityAndPad = float4(vel, sleepCounter);
}

// MARK: - Mesh Expansion Kernel
// Expands each particle into a subdivided icosahedron (42 vertices, 80 tri-faces).
// Thread per vertex: tid = particleIdx * 42 + vertexIdx

struct MeshVertex {
    packed_float3 position;  // 12 bytes
    packed_float3 normal;    // 12 bytes
    uchar4 color;            // 4 bytes (RGBA)
};  // 28 bytes total

// Subdivided icosahedron: 12 original vertices + 30 edge midpoints, all on unit sphere
constant float3 ico_verts[42] = {
    float3(-0.525731,  0.850651,  0.000000),
    float3( 0.525731,  0.850651,  0.000000),
    float3(-0.525731, -0.850651,  0.000000),
    float3( 0.525731, -0.850651,  0.000000),
    float3( 0.000000, -0.525731,  0.850651),
    float3( 0.000000,  0.525731,  0.850651),
    float3( 0.000000, -0.525731, -0.850651),
    float3( 0.000000,  0.525731, -0.850651),
    float3( 0.850651,  0.000000, -0.525731),
    float3( 0.850651,  0.000000,  0.525731),
    float3(-0.850651,  0.000000, -0.525731),
    float3(-0.850651,  0.000000,  0.525731),
    float3(-0.809017,  0.500000,  0.309017),
    float3(-0.500000,  0.309017,  0.809017),
    float3(-0.309017,  0.809017,  0.500000),
    float3( 0.309017,  0.809017,  0.500000),
    float3( 0.000000,  1.000000,  0.000000),
    float3( 0.309017,  0.809017, -0.500000),
    float3(-0.309017,  0.809017, -0.500000),
    float3(-0.500000,  0.309017, -0.809017),
    float3(-0.809017,  0.500000, -0.309017),
    float3(-1.000000,  0.000000,  0.000000),
    float3( 0.500000,  0.309017,  0.809017),
    float3( 0.809017,  0.500000,  0.309017),
    float3(-0.500000, -0.309017,  0.809017),
    float3( 0.000000,  0.000000,  1.000000),
    float3(-0.809017, -0.500000, -0.309017),
    float3(-0.809017, -0.500000,  0.309017),
    float3( 0.000000,  0.000000, -1.000000),
    float3(-0.500000, -0.309017, -0.809017),
    float3( 0.809017,  0.500000, -0.309017),
    float3( 0.500000,  0.309017, -0.809017),
    float3( 0.809017, -0.500000,  0.309017),
    float3( 0.500000, -0.309017,  0.809017),
    float3( 0.309017, -0.809017,  0.500000),
    float3(-0.309017, -0.809017,  0.500000),
    float3( 0.000000, -1.000000,  0.000000),
    float3(-0.309017, -0.809017, -0.500000),
    float3( 0.309017, -0.809017, -0.500000),
    float3( 0.500000, -0.309017, -0.809017),
    float3( 0.809017, -0.500000, -0.309017),
    float3( 1.000000,  0.000000,  0.000000)
};

kernel void expandMeshes(
    device const GPUParticle* particles     [[buffer(0)]],
    device MeshVertex*        outVertices   [[buffer(1)]],
    constant uint&            particleCount [[buffer(2)]],
    constant float&           radius        [[buffer(3)]],
    device const uchar4*      colors        [[buffer(4)]],
    uint tid [[thread_position_in_grid]]
) {
    uint particleIdx = tid / 42;
    uint vertexIdx = tid % 42;
    if (particleIdx >= particleCount) return;

    float3 center = particles[particleIdx].positionAndRadius.xyz;
    float3 templatePos = ico_verts[vertexIdx];

    MeshVertex v;
    v.position = center + templatePos * radius;
    v.normal = templatePos;  // Unit length — vertices lie on unit sphere
    v.color = colors[particleIdx];
    outVertices[tid] = v;
}

// MARK: - Snap After Flip Kernel

kernel void snapAfterFlip(
    device GPUParticle* particles [[buffer(0)]],
    uint tid [[thread_position_in_grid]],
    device const uint& particleCount [[buffer(1)]]
) {
    if (tid >= particleCount) return;

    // Rotation by π around X axis: (x, y, z) → (x, -y, -z)
    particles[tid].positionAndRadius.y = -particles[tid].positionAndRadius.y;
    particles[tid].positionAndRadius.z = -particles[tid].positionAndRadius.z;
    particles[tid].velocityAndPad.y = -particles[tid].velocityAndPad.y;
    particles[tid].velocityAndPad.z = -particles[tid].velocityAndPad.z;
    particles[tid].velocityAndPad.w = 0.0;  // reset sleep counters — all particles awake after flip
}
