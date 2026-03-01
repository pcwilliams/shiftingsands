# Apple Dev - Claude Code Project Conventions

This folder contains native iOS apps built entirely through conversation with Claude Code. This file captures the shared principles, patterns, and preferences that apply across all projects.

## Tech Stack

Every project uses the same foundation:

- **Language:** Swift 5
- **UI Framework:** SwiftUI (no storyboards, no XIBs)
- **Minimum Target:** iOS 17.0+ (some projects use iOS 18.0+)
- **Xcode:** 16+
- **Device:** iPhone only (`TARGETED_DEVICE_FAMILY = 1`)
- **Orientation:** Portrait only
- **Dependencies:** Zero external dependencies — pure Apple frameworks only (SwiftUI, MapKit, CoreLocation, Photos, CryptoKit, Swift Charts, etc.)

## Architecture

All projects follow **MVVM** with SwiftUI's reactive data binding:

- **View models** are `ObservableObject` classes with `@Published` properties, observed via `@StateObject` in views
- **Views** are declarative SwiftUI — no UIKit unless wrapping a system controller (e.g. `SFSafariViewController`)
- **Services/API clients** use the `actor` pattern for thread safety
- **Networking** uses native `URLSession` with `async/await` — no external HTTP libraries
- **View models** are annotated `@MainActor` when they drive UI state

## Project Structure

Each project follows this standard layout:

```
ProjectName/
├── ProjectName.xcodeproj/
├── CLAUDE.md                    # Developer reference (this kind of file)
├── README.md                    # User-facing documentation
├── architecture.html            # Interactive Mermaid.js architecture diagrams
├── tutorial.html                # Build narrative with prompts and responses
└── ProjectName/
    ├── App/
    │   ├── ProjectNameApp.swift # @main entry point
    │   └── ContentView.swift    # Root view / navigation
    ├── Models/                  # Data model structs and SwiftData @Models
    ├── Views/                   # SwiftUI views
    │   └── Components/          # Reusable view components
    ├── Services/                # API clients, managers, business logic
    ├── ViewModels/              # ObservableObject state management
    ├── Extensions/              # Formatters and helpers
    └── Assets.xcassets/
        ├── AppIcon.appiconset/  # 1024x1024 icons (standard, dark, tinted)
        └── AccentColor.colorset/
```

Smaller projects (e.g. Where) may flatten this into fewer files — the principle is simplicity over ceremony.

## Xcode Project File (project.pbxproj)

Projects are created and maintained by writing `project.pbxproj` directly, not via the Xcode GUI. When adding new Swift files to a target that doesn't use file system sync, register in four places:

1. **PBXBuildFile section** — build file entry
2. **PBXFileReference section** — file reference entry
3. **PBXGroup** — add to the appropriate group's `children` list
4. **PBXSourcesBuildPhase** — add build file to the target's Sources phase

ID patterns vary per project but follow a consistent incrementing convention within each project. Test targets may use `PBXFileSystemSynchronizedRootGroup` (Xcode 16+), meaning test files are auto-discovered.

## Build Verification

Always verify the build after any code change:

```bash
xcodebuild -project ProjectName.xcodeproj -scheme ProjectName \
  -destination 'generic/platform=iOS' build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

A clean result ends with `** BUILD SUCCEEDED **`. Fix any errors before considering a task complete.

## Testing

```bash
xcodebuild -project ProjectName.xcodeproj -scheme ProjectName \
  -destination 'platform=iOS Simulator,name=iPhone 16' test \
  CODE_SIGNING_ALLOWED=NO
```

- Use **in-memory containers** for SwiftData tests (fast, isolated)
- Use the **Swift Testing framework** (`import Testing`, `@Test`, `#expect()`) for newer projects
- **Extract pure decision logic as `internal static` methods** with explicit parameters so tests can inject values directly — avoid testing through singletons, UserDefaults, or system frameworks
- Test files that use Foundation types must `import Foundation` alongside `import Testing`

## Key Patterns

### Persistence

- **SwiftData** for structured app data (e.g. PillRecord)
- **UserDefaults / @AppStorage** for preferences, settings, and cache
- **iOS Keychain** for API credentials and secrets (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
- **JSON encoding** in UserDefaults for lightweight structured data (e.g. portfolio, saved places)

### Networking

- **Graceful degradation:** The app should work with reduced functionality when API calls fail. Isolate independent API calls in separate `do/catch` blocks so one failure doesn't take down the others
- **Task cancellation:** Cancel in-flight tasks before starting new ones. Check `Task.isCancelled` before publishing results
- **Debouncing:** Use 0.8-second debounce for rapid user interactions (e.g. map panning) to prevent API spam
- **Caching:** Cache API responses with TTLs in UserDefaults (e.g. 5-min for quotes, 30-min for historical data)

### Concurrency

- **Actor-based services** for thread-safe API clients
- **`async let` for parallel fetching** of independent data
- Wrap work in an unstructured `Task` inside `.refreshable` to prevent SwiftUI from cancelling structured concurrency children when `@Published` properties trigger re-renders
- **`Task.detached(.utility)`** for background work like photo library scanning
- **Swift 6 concurrency:** Use `guard let self else { return }` in detached task closures; copy mutable `var` to `let` before `await MainActor.run`

### Timers

- Prefer **one-shot `DispatchWorkItem`** over polling `Timer.publish`
- Avoid always-running timers — schedule on demand, cancel on completion

### SwiftUI

- **`.id()` modifier** on views for animated identity changes (e.g. month transitions)
- **GeometryReader** for proportional layouts
- **Asymmetric slide transitions** with tracked direction state
- **NavigationStack** with `.toolbar` and `.sheet` for settings
- **`.refreshable`** for pull-to-refresh
- **Segmented pickers** for mode selection (chart periods, map styles, etc.)
- **@AppStorage** for persisting UI preferences across launches
- **`.contentShape(Rectangle())`** for full-row tap targets

## App Icons

Generated programmatically using **Python/Pillow** — not designed in a graphics tool. Three variants at 1024x1024:

- **Standard** (light mode)
- **Dark** (dark mode)
- **Tinted** (greyscale for tinted mode)

Referenced in `Contents.json` with `luminosity` appearance variants. Use `Image.new("RGB", ...)` not `"RGBA"` — iOS strips alpha for app icons, causing compositing artefacts with semi-transparent overlays.

## Documentation

Each project includes four living documents that must be kept up to date as the project evolves:

### CLAUDE.md (developer reference)

The comprehensive knowledge base for Claude Code sessions. Must be updated whenever:
- A new file, model, view, or service is added or removed
- An architectural decision is made or changed
- A new API is integrated or an existing one changes
- A non-obvious bug is fixed or a gotcha is discovered
- Build configuration, test coverage, or project structure changes

This is the single source of truth for project context. A future session should be able to read CLAUDE.md and understand the entire project without exploring the codebase.

### README.md (user-facing)

The public-facing project overview. Must be updated whenever:
- Features are added, changed, or removed
- Setup instructions change (new dependencies, API keys, permissions)
- The project structure changes significantly
- Screenshots become outdated (note when a new screenshot is needed)

Keep it concise and practical — someone should be able to clone the repo and get running by following the README.

### architecture.html (architecture diagrams)

Interactive Mermaid.js diagrams rendered in a standalone HTML file. Must be updated whenever:
- The view hierarchy changes (new views, removed views, restructured navigation)
- Data flow changes (new services, new API integrations, changed data pipelines)
- New major subsystems are added (e.g. a notification system, a caching layer, a P&L calculator)

Use `graph TD` (top-down) for readability on narrow screens. Load Mermaid.js from CDN. Apply the shared dark theme with CSS custom properties and project-appropriate accent colours.

### tutorial.html (build narrative)

A step-by-step record of how the app was built through Claude Code conversation. Must be updated whenever:
- A significant new feature is added via a notable prompt interaction
- A major refactor or architectural change is made
- An interesting problem is solved through iterative prompting

Capture the essence of the prompt, the approach taken, and the outcome. This documents the collaborative development process and serves as a guide for building similar features in future projects.

**Prompt tone:** Prompts recorded in the tutorial should sound collaborative, not demanding. Use phrases like "Could we try...", "How about...", "Would you mind...", "Would it be worth...", "I'd love it if..." rather than "Make...", "Add...", "I want...", "I need...". When describing problems, use "I'm seeing..." or "I'm noticing..." rather than assertive declarations. The tone should reflect a partnership — two people working together on something, not instructions being issued.

### Formatting conventions

- Use plain Markdown in `.md` files (no inline HTML except README badges). Images must use `![alt](src)` syntax, not `<img>` tags
- HTML docs use a shared dark theme with CSS custom properties and Mermaid.js loaded from CDN
- HTML docs include a hero screenshot in a phone-frame wrapper (black background, rounded corners, drop shadow) below the title/badges

## Common Gotchas

- **Keychain: always delete before add** to avoid `errSecDuplicateItem`
- **SwiftUI `.refreshable` cancels structured concurrency** — wrap network calls in an unstructured `Task`
- **Wikimedia geosearch caps at 10,000m radius** — clamp before sending
- **Wikipedia disambiguation pages** — filter out articles where extract contains "may refer to"

---

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

See `../CLAUDE.md` for shared conventions across all projects (MVVM architecture, SwiftUI patterns, build commands, testing, project structure, documentation requirements, etc.).

## What Is ShiftingSands?

An hourglass egg timer app for iPhone 16 Pro featuring a real-time granular physics simulation. Golden sand-coloured balls flow through a procedurally-generated glass hourglass, driven by one of three physics/rendering modes: CPU-based (up to 250 particles), GPU-accelerated with SceneKit node rendering (Metal compute + CPU readback, up to 10,000 particles), or Metal mode with GPU-only rendering (Metal compute + mesh expansion, up to 50,000 particles — zero CPU readback). All modes feature full O(N²) sphere-sphere collision at every count, glass wall collision, and gravity rotation during the flip animation. Particles are sized to fill ~25% of the lower chamber volume. A digital readout overlays the 3D scene. Duration slider from 5 seconds to 30 seconds. Flow rate is controlled by a combination of **gravity scaling** and **neck friction**: gravity scales inversely with duration (`gravityScale = max(5.0 / duration, 0.15)` — full gravity 1.0 at 5s, ~0.17 at 30s), while neck friction adds extra damping near the constriction. Starts in GPU mode with 5,000 particles. A particle size slider (0.5×–1.5×) adjusts fill level from a thin bottom layer to half the chamber. Optional random color mode assigns each particle a unique hue (HSB: random hue, 0.7 saturation, 0.85 brightness) — in Metal mode, per-vertex colors are passed through the mesh expansion kernel. Physics mode, particle count, size multiplier, duration, and random colors are persisted across launches.

This is an experimental, graphics-first project — the priority is stunning visuals and satisfying physics.

## Build & Run

```bash
# Build (must end with ** BUILD SUCCEEDED **)
xcodebuild -project ShiftingSands.xcodeproj -scheme ShiftingSands \
  -destination 'generic/platform=iOS' build \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5

# Build for simulator (visual testing)
xcodebuild -project ShiftingSands.xcodeproj -scheme ShiftingSands \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build \
  CODE_SIGNING_ALLOWED=NO
```

## Testing

### Unit Tests

```bash
# Run unit tests (Swift Testing framework)
xcodebuild -project ShiftingSands.xcodeproj -scheme ShiftingSands \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
  CODE_SIGNING_ALLOWED=NO
```

**Test target**: `ShiftingSandsTests` with `PBXFileSystemSynchronizedRootGroup` (Xcode 16+ auto-discovery). Uses Swift Testing framework (`import Testing`, `@Test`, `#expect()`).

16 tests total across two files:

| Test File | Coverage |
|-----------|----------|
| `CPUPhysicsTests.swift` (10 tests) | Gravity, floor bounce, sphere collision, flip transform, full drain (50 particles), settling, spawn packing stays in lower chamber (10k at size 1.3), spawn packing at various sizes (5k at 0.5/1.0/1.3/1.5), spawn top layer flatness, wall containment |
| `GPUPhysicsTests.swift` (6 tests) | Gravity, floor containment, flip transform, full drain (100 particles), settling + sleep verification, sleeping particle wakes when support removed |

### Simulator Testing

Launch arguments for automated testing:

```bash
# Test mode: 10s duration, auto-start, dumps particle data on completion
xcrun simctl launch booted PW.ShiftingSands -- -test

# Auto-start only (no data dump, uses persisted duration/mode)
xcrun simctl launch booted PW.ShiftingSands -- -autostart

# Launch with random colors enabled
xcrun simctl launch booted PW.ShiftingSands -- -multicolor

# CLI overrides (mode must be set before count/size):
# -mode cpu|gpu|metal   Override physics mode
# -count N              Override particle count
# -size F               Override size multiplier (e.g. 1.3)
# -dumpspawn            Dump spawn state histogram to Documents/spawn_state.txt after 2s delay
xcrun simctl launch booted PW.ShiftingSands -- -mode metal -count 10000 -size 1.3 -dumpspawn

# Read test results (after ~16s: 2s delay + 1.2s flip + 10s timer + margin)
CONTAINER=$(xcrun simctl get_app_container booted PW.ShiftingSands data)
head -6 "$CONTAINER/Documents/test_results.txt"

# Read spawn state dump
head -30 "$CONTAINER/Documents/spawn_state.txt"
```

**Test output** (`Documents/test_results.txt`): summary stats (upper/lower count, sleeping count, avg/max speed) + per-particle positions, velocities, and sleep counters. Key metrics for physics tuning:
- `upper=0` — all particles drained (100% means flow works)
- `sleeping=N deepSleep=N` — all settled (means sleep system works)
- `avgSpeed=0.000000` — all at rest (means damping/cutoff works)

## File Overview

| File | Purpose |
|------|---------|
| `ShiftingSandsApp.swift` | Minimal `@main` entry point |
| `ContentView.swift` | ZStack: full-screen 3D scene + timer overlay. Top-left: Colors toggle (padded .leading 24, .top 8). Top-right (padded .top 8): physics mode picker + size slider + count slider (always enabled, changes during animation trigger instant restart). Bottom-left: time remaining readout. Bottom-right: duration slider (5-30s) + presets (5s/10s/30s) + start/reset. Processes CLI args on appear: `-mode`, `-count`, `-size`, `-dumpspawn`, `-test`, `-autostart`, `-multicolor` |
| `TimerViewModel.swift` | `@MainActor ObservableObject` — two-phase start (`startFlip` → `completeFlip`), physics mode, particle count, particle size multiplier, duration, randomColors. Persists mode, per-mode particle count, per-mode size multiplier, duration ("timerDuration"), and randomColors ("randomColors") in UserDefaults. `dumpSpawnState()` dumps particle spawn positions with Y histogram to Documents/spawn_state.txt |
| `HourglassScene.swift` | Builds the `SCNScene`: container node, glass (dynamic neck), particle spheres/mesh, flip animation, lighting, camera. Thread-safe particle access via NSLock. Integrates CPU, GPU, and Metal instanced physics. Accepts `randomColors` param for per-particle color assignment |
| `HourglassSceneView.swift` | `UIViewRepresentable` wrapping `SCNView` with per-frame physics delegate, dispatches to CPU, GPU, or Metal instanced mode. SceneKit backgroundColor .clear + isPlaying = true to remove startup fade. Gravity scaling (`gravityScale = max(5.0 / duration, 0.15)`) computed per-frame in Coordinator. Unconditionally respawns particles before every flip and on every reset/completion |
| `SandGeometry.swift` | Procedural geometry: surface of revolution, dynamic neck profiles, inner radius lookup |
| `GranularSimulation.swift` | CPU-based granular physics: O(N²) sphere-sphere collision, glass wall collision, gravity rotation. Also provides shared `packedPositions()` hex-packed spawning used by all modes |
| `MetalPhysicsEngine.swift` | GPU-accelerated physics via Metal compute shaders: double-buffered particles, profile lookup table, mesh expansion compute kernel, safe array readback. Color buffer (`MTLBuffer` of `uchar4`, one per particle) for random color mode |
| `ParticlePhysics.metal` | Metal compute kernels: `physicsStep` (full O(N²) physics per particle), `snapAfterFlip`, and `expandMeshes` (subdivided icosahedron mesh expansion for Metal instanced mode — 42 verts, 80 faces per particle, 28-byte `MeshVertex` with per-vertex color) |
| `generate_icons.py` | Python/Pillow script generating three 1024×1024 app icons (standard, dark, tinted). Uses the exact Catmull-Rom hourglass profile from `SandGeometry.swift` with hex-packed golden sand balls at the bottom of the lower chamber, glass edge highlights, wooden caps, and deep charcoal background |
| `ShiftingSandsTests/` | Test target directory (PBXFileSystemSynchronizedRootGroup, auto-discovered) |
| `CPUPhysicsTests.swift` | Swift Testing: gravity, floor bounce, sphere collision, flip transform, full drain (50 particles), settling, spawn packing (lower chamber containment at 10k/1.3× and various sizes), spawn top layer flatness, wall containment |
| `GPUPhysicsTests.swift` | Swift Testing: gravity, floor containment, flip transform, full drain (100 particles), settling + sleep verification, sleeping particle wakes when support removed |

## Architecture

### Rendering: SceneKit via UIViewRepresentable

The app uses **SceneKit** wrapped in `UIViewRepresentable` (NOT SwiftUI's `SceneView`) because `SceneView` lacks `SCNSceneRendererDelegate` access needed for per-frame physics updates.

The `HourglassSceneView.Coordinator` holds the `HourglassScene` instance (stable across SwiftUI view updates) and implements `SCNSceneRendererDelegate`. It dispatches to `updateGranularSimulation(dt:)` (CPU), `updateMetalSimulation(dt:)` (GPU), or `updateInstancedSimulation(dt:)` (Metal) based on `currentPhysicsMode`.

### Scene Node Hierarchy

All hourglass geometry lives under a **container node** (`hourglassContainer`) so the entire hourglass can be rotated for the flip animation. Camera and lights are direct children of `scene.rootNode` (they stay fixed during flips).

```
scene.rootNode
├── hourglassContainer
│   ├── outerGlassNode (visible, Blinn material)
│   ├── innerGlassNode (invisible, concavePolyhedron physics collider)
│   ├── topCapNode, bottomCapNode (wooden frame)
│   ├── particlesContainer (CPU/GPU modes)
│   │   └── N × sphere nodes (shared SCNSphere geometry, golden Lambert material)
│   └── rendererNode (Metal mode only)
│       └── SCNGeometry(.triangles) from mesh expansion MTLBuffer
├── cameraNode (fixed, not affected by flip)
└── 5 light nodes (fixed)
```

### Hourglass Glass

Programmatic geometry — no imported 3D models. The hourglass profile is defined as ~11 control points in `SandGeometry`, interpolated with **Catmull-Rom splines** into ~80 smooth profile points, then rotated around the Y axis as a **surface of revolution** (64 angular segments) to produce custom `SCNGeometry` from `SCNGeometrySource`/`SCNGeometryElement`.

Two glass surfaces exist:
- **Outer glass** — visible, Blinn lighting model (diffuse alpha 0.10, specular 0.15, shininess 30, `dualLayer` transparency, `writesToDepthBuffer = false`)
- **Inner glass** — invisible (`opacity = 0`), offset inward by `wallThickness` (0.008), provides `concavePolyhedron` static physics body for particle collisions

Using **Blinn** instead of PBR for glass was a deliberate choice — PBR environment reflections added unwanted brightness regardless of transparency settings.

### Dynamic Neck Width

The hourglass neck width adjusts automatically based on particle size so exactly **one ball fits through at a time**. When `setupGranularParticles(count:sizeMultiplier:)` or `setupMetalParticles(count:sizeMultiplier:)` is called:

1. Compute particle radius: `0.030 × (100/N)^(1/3) × packingCorrection × sizeMultiplier` (see `radiusForCount`)
2. Compute neck outer radius: `particleRadius + wallThickness + 0.002` (tight clearance — barely fits one ball)
3. Call `SandGeometry.setNeckRadius()` to regenerate the glass profiles with steep funnel shoulders
4. Call `rebuildGlass()` to recreate both glass surfaces with the new profile

The neck funnel is deliberately steep — shoulder control points sit at ±0.04 height (not ±0.08) with radius `neckRadius × 1.8`, creating a sharp constriction that forces single-file flow and natural particle backup/jamming.

The `activeOuterProfile` and `activeInnerProfile` static vars on `SandGeometry` store the current profiles. `innerRadiusAt(y:)` uses the active inner profile, so the granular simulation's wall collision automatically follows the updated glass shape.

### Physics Mode: CPU

The CPU physics engine (`GranularSimulation.swift`) uses O(N²) brute force sphere-sphere collision on a single thread. Each particle is a `SimParticle` with position, velocity, and radius (all `SIMD3<Float>`/`Float`). Capped at 250 particles (slider max in CPU mode).

**Physics constants**: gravity scales inversely with duration (`gravityScale = max(5.0 / duration, 0.15)` — full gravity 1.0 at 5s, ~0.17 at 30s), restitution 0.02, friction 0.6. **Two damping layers** (CPU): (1) neck friction near the constriction, (2) velocity-dependent damping — blends between gentle flow (0.92/s) at high speed and aggressive settle (0.05/s) at low speed, threshold 0.15. No sleep system — CPU's sequential collision resolution converges naturally. Flow rate controlled by gravity scaling + neck friction (see Neck Friction and Gravity Scaling).

**Adaptive substeps**: 4 for <=500 particles, 3 for 501-1000, 2 for >1000. Each substep: gravity → position update → wall collision → floor/ceiling → sphere-sphere → neck friction → velocity damping.

**Wall collision**: exploits rotational symmetry — compute `r = sqrt(x²+z²)` and compare against `SandGeometry.innerRadiusAt(y:)` (linear search through ~80 profile points).

### Physics Mode: GPU (Metal Compute)

The GPU physics engine (`MetalPhysicsEngine.swift` + `ParticlePhysics.metal`) parallelises the O(N²) collision across GPU threads. Each thread handles one particle: applies gravity, updates position, resolves wall/floor/ceiling collisions, loops over all other particles for sphere-sphere collision, and applies damping.

**Key design decisions**:
- **Double-buffered particle data** — read from buffer A, write to buffer B, swap after each substep. Avoids race conditions when parallel threads read/write overlapping particle pairs.
- **`storageModeShared` MTLBuffers** — zero-copy CPU/GPU access on iOS (unified memory). CPU writes initial positions, GPU runs physics, CPU reads back positions to update SCNNodes.
- **Synchronous `waitUntilCompleted`** per substep — simpler than async triple-buffering. At 2000 particles, each substep takes ~0.5ms on GPU.
- **Pre-computed 256-entry radius lookup table** — `SandGeometry.innerRadiusAt(y:)` sampled at 256 Y values, uploaded to a Metal buffer. GPU does O(1) interpolated lookup instead of O(80) linear search.
- **Chamber-asymmetric collision resolution** — the fundamental challenge of GPU physics: CPU resolves collisions sequentially so forces propagate through a pile in one pass. GPU threads all read the same stale snapshot, so corrections oscillate and impulses cancel gravity, jamming packed piles. The solution splits behavior by chamber:
  - **Lower chamber (pos.y < 0)**: full 0.25 position correction + 0.25 velocity impulse for all approaching contacts. Transmits the pile's normal force chain for stable resting. Aggressive velocity-dependent damping (settle blend). Velocity cutoff at 0.01.
  - **Upper chamber (pos.y > 0)**: 0.25 position correction (prevents overlap) but **no velocity impulse** (gravity dominates — pile drains freely). Flow-only damping (`pow(0.92, subDt)`). No velocity cutoff (tiny gravity increments must accumulate). No sleep (particles stay awake until they reach the lower chamber).
- **Two-tier sleep system (lower chamber only, contact-based)** — per-particle sleep counter in `velocityAndPad.w`. A `contactCount` is tracked during the O(N²) collision loop. Only particles with `hasSupport` (contactCount > 0) can have velocity zeroed or enter sleep — free-falling particles with zero contacts never freeze, preventing mid-air suspension. Speed < 0.08 with contacts increments the counter (generous threshold catches surface oscillation at ~0.05 from parallel collision). Counter 16-30: "light sleep" — O(N) wake-up check per frame; wakes only if a non-sleeping neighbor is approaching fast (`relVelNormal < -0.05`). Support-loss detection is deferred to the deep sleep staggered check — using `sleepContactCount` in light sleep caused oscillation (particles barely separated from neighbors woke every ~15 frames, creating visible blur through the glass). Counter > 30: "deep sleep" — **staggered support check** every 30 frames (offset by thread ID, so ~N/30 particles check per frame): floor contact counts as support (cheap check, no neighbor scan), otherwise scans for nearby particles within 1.05x touching distance; if no support found, particle wakes and falls. Staggering reduces deep sleep overhead from O(N²) to O(N²/30) per frame, preventing frame rate drops during settling. `snapAfterFlip` resets all counters to 0. Upper-chamber particles always have counter = 0. This eliminates the O(N²) cost when all particles are at rest while ensuring particles wake when their support is removed (within ~0.5s).
- **Floor/ceiling resting contact** — after bounce, if `abs(vel.y) < gravity * subDt * 2.0`, vel.y is zeroed. Prevents micro-bounce cycle.

**GPU particle struct**: `GPUParticle` = `float4 positionAndRadius` + `float4 velocityAndPad` = 32 bytes, naturally aligned. `velocityAndPad.w` stores the per-particle sleep counter (0 = awake; increments in lower chamber when speed < 0.08 AND contactCount > 0; 16-30 = light sleep with O(N) wake-up check, wakes only on approaching non-sleeping neighbor; >30 = deep sleep with staggered support verification every 30 frames (floor contact or nearby particle scan at 1.05x distance, wakes if unsupported); upper chamber always 0; free-falling particles with zero contacts always stay awake).

**Threadgroup sizing**: 256 threads per threadgroup, `ceil(N/256)` threadgroups. Capped at 10,000 particles (slider max in GPU mode, default 5,000).

**Hex-packed spawning**: Particles are spawned in hexagonal close-packed layers filling the lower chamber from bottom up (shared `GranularSimulation.packedPositions()` algorithm). This produces a near-resting-state configuration with minimal settling needed. No pre-simulation settling loops.

**Adaptive substeps (GPU)**: 4 for <=1500 particles, 3 for 1501-3000, 2 for 3001-10000, 1 for >10000.

**Metal kernels** (`ParticlePhysics.metal`):
- `physicsStep` — full physics step per particle per substep: two-tier sleep check (deep sleep at counter >30 with staggered support verification every 30 frames — floor contact or nearby particle scan at 1.05x distance, wakes if unsupported; light sleep O(N) wake-up at 16-30, wakes only on approaching non-sleeping neighbor), gravity, position update, wall collision, floor/ceiling with resting contact, O(N²) sphere-sphere collision (position correction everywhere, impulse lower-chamber only, tracks `contactCount`), neck friction, chamber-dependent damping (flow-only upper, settle-blend lower), contact-based velocity cutoff (lower only, requires `hasSupport` = contactCount > 0), contact-based sleep counter update (lower only, threshold 0.08, requires contacts)
- `snapAfterFlip` — `(x,y,z)→(x,-y,-z)`, `(vy,vz)→(-vy,-vz)` transform, resets all sleep counters to 0 (wakes deep-sleeping particles)
- `expandMeshes` — subdivided icosahedron mesh expansion for Metal instanced mode (42 verts, 80 faces per particle, 28-byte MeshVertex with per-vertex color from color buffer)

### Physics/Rendering Mode: Metal (Mesh Expansion)

The Metal mode eliminates the CPU readback bottleneck. Physics runs on the GPU (reusing `MetalPhysicsEngine`), then a second compute kernel expands each particle into a subdivided icosahedron mesh (nearly spherical). `SCNGeometrySource(buffer:)` wraps the expanded vertex buffer — zero CPU-side position copies, real 3D geometry with proper lighting.

**Data flow comparison**:
- **GPU mode**: Metal Compute → `readPositions()` CPU copy → O(N) SCNNode updates → SceneKit renders N nodes
- **Metal mode**: Physics Compute → Mesh Expansion Compute (particle → icosahedron vertices) → `SCNGeometrySource(buffer:)` wraps expanded buffer → SceneKit renders triangle geometry

**Key design decisions**:
- **Mesh expansion compute kernel** (`expandMeshes` in `ParticlePhysics.metal`) — each thread generates one vertex of the expanded mesh. Thread count = `particleCount × 42` (subdivided icosahedron has 42 vertices). Reads particle position from physics buffer, applies template vertex × radius + position. Output: `MeshVertex` struct = `packed_float3 position + packed_float3 normal + uchar4 color` (28 bytes/vertex). When random colors are enabled, copies the particle's color from the color buffer to all 42 vertices; otherwise uses default golden sand color.
- **Subdivided icosahedron mesh** — 42 vertices, 80 triangular faces (240 indices) per particle. Generated by taking a regular icosahedron (12 verts, 20 faces) and subdividing each edge with a midpoint projected onto the unit sphere (30 new verts), splitting each face into 4 sub-triangles. At 50k particles: 2.1M vertices (~50 MB) + 12M indices (~48 MB). All 42 vertices are unit vectors, so vertex normals = vertex positions — gives nearly-spherical shading that closely matches CPU/GPU sphere appearance.
- **Pre-computed index buffer** — static pattern (same 240 indices per particle, offset by vertex base). Built once in `buildMeshBuffers()`, reused every frame.
- **Lambert material** — golden sand (0.76/0.60/0.28). Lambert lighting model (no specular/Fresnel) prevents white blowout. Works properly because icosahedron vertices have real normals (unlike point primitives which produced dark/invisible particles).
- **Per-frame pipeline** — `engine.step()` → `engine.expandMeshes()` → rebuild `SCNGeometry` wrapping the same vertex/index Metal buffers. Geometry creation is lightweight (Swift objects wrapping existing MTLBuffers).
- **`SCNNodeRendererDelegate` abandoned** — the original plan used custom Metal draw calls via `SCNNodeRendererDelegate`, but extensive testing revealed that custom `drawIndexedPrimitives` calls produce no visible pixels in modern SceneKit's multi-pass rendering pipeline. The mesh expansion approach works reliably through SceneKit's standard rendering path.

**Collision scaling** (same for GPU and Metal modes — always full O(N²)):
| Count | Substeps |
|-------|----------|
| ≤1,500 | 4 |
| 1,501–3,000 | 3 |
| 3,001–10,000 | 2 |
| >10,000 | 1 |

**Particle limits**: slider max 50,000 in Metal mode (default 10,000). GPU max 10,000 (default 5,000). CPU max 250 (default 100).

### Flip Animation

Instead of instantly starting, the timer begins with a **180° flip animation** of the hourglass. The glass and frame caps are geometrically symmetric about Y=0, so rotating 180° around the X axis produces an identical shape.

1. Real particles tumble with physics as gravity direction rotates with the container
2. `hourglassContainer` rotates from 0 to pi via `SCNAction.rotateBy` (1.2s, easeInEaseOut)
3. On completion, snap `eulerAngles` back to (0,0,0) — invisible because glass is symmetric
4. Transform all particle positions/velocities: `snapAfterFlip()` (CPU or GPU kernel)
5. Particles that were at the bottom are now at the top and begin falling through the neck
6. Timer starts counting

**Two-phase start pattern:** `TimerViewModel.startFlip()` sets `isFlipping=true` (triggers the flip). The flip animation's completion callback calls `TimerViewModel.completeFlip()` which sets `isRunning=true` and creates the timer task.

### Gravity Scaling

Gravity scales inversely with duration to slow particle flow at longer timings:

- `gravityScale = max(5.0 / duration, 0.15)` (computed per-frame in the Coordinator)
- At 5s: full gravity (1.0) — fast, energetic flow
- At 10s: 0.5 — noticeably slower, gentle flow
- At 30s: ~0.17 — very slow, gentle trickle
- Floor at 0.15 prevents particles from becoming too sluggish at maximum duration

The Coordinator sets `gravity` on the active physics engine (`granularSim` or `metalEngine`) each frame. Both CPU and GPU engines use this value as the gravity magnitude in their physics step.

### Neck Friction (Flow Rate Control)

Flow rate is controlled by a combination of **gravity scaling** and **neck friction**. The constriction near y=0 applies extra velocity damping, scaled by the selected duration:

- `neckDamping = duration * 0.02` (computed per-frame in the Coordinator)
- Applied in a zone where `|y| < neckHalfHeight` (0.10)
- Damping ramps up linearly toward the centre: `neckFactor = 1 - |y| / neckHalfHeight`
- Velocity *= `max(0, 1 - neckFactor * neckDamping * subDt)`

At 5s: mild neck friction (neckDamping=0.1) + full gravity (1.0), fast flow. At 30s: stronger friction (neckDamping=0.6) + reduced gravity (~0.17), slow trickle. Particles speed up again after passing through the constriction — gravity scaling ensures natural-looking acceleration at all durations.

### Thread Safety

`HourglassScene` uses an `NSLock` (`particleLock`) to protect `particleSphereNodes`, `granularSim`, and `metalEngine` from concurrent access between the SceneKit render thread (`renderer(updateAtTime:)`) and the main thread (setup/teardown from `updateUIView`). All `setup*`, `teardown*`, and `update*Simulation` methods acquire the lock. The flip completion handler also acquires it. `MetalPhysicsEngine.readPositions()` returns a safe `[GPUParticle]` copy (not an `UnsafeBufferPointer`) to prevent dangling pointer crashes during teardown.

### Timer Flow

```
Resting (particles settled at bottom)
    | User taps "Start"
    v
    | Rebuild particles only if count/size/color changed
    v
Flipping (isFlipping=true, 1.2s rotation, particles tumble with real physics)
    | Animation completes -> completeFlip()
    v
Running (isRunning=true, particles flow through neck)
    | elapsed reaches duration          | User changes mode/count/size
    v                                   v
Complete (isComplete=true,           restart() → reset + re-setup + startFlip
particles at rest at bottom)
    | User taps "Start" (button shows "Start", not "Reset")
    v
reset + immediate startFlip (particles stay where they are unless settings changed)
```

**Reset respawns, completion does not**: Manual Reset respawns all particles at the bottom via `setup*Particles`. Natural timer completion leaves particles at rest where they settled — no respawn. Flip start only rebuilds if count/size/color changed since last setup. This prevents visual jumps when transitioning between runs.

### UI Layout

**Top-left** (padded `.leading 24`, `.top 8`): Colors toggle (random color mode). **Top-right** (padded `.top 8`): physics mode picker (CPU/GPU/Metal segmented control), particle size slider (0.5×–1.5×, step 0.05, default 1.0×), particle count slider (50-250 CPU / 50-10000 GPU / 50-50000 Metal, step 50). All controls are **always enabled**. Mode changes during animation trigger an instant restart. Count/size slider changes are **deferred** — the new values take effect on next start, reset, or mode change (prevents freezing from rapid particle rebuilds during animation). **Bottom-left**: digital readout (48pt monospaced). **Bottom-right**: duration slider (5s-30s, step 5s) with quick preset buttons (5s/10s/30s), and start/reset button. Duration controls disabled during flip/running. After timer completes (isComplete), button shows "Start" — pressing it resets and immediately starts a new flip. Particle count label shows "k" format for counts ≥1000 (e.g. "50k particles").

### Data Flow

```
TimerViewModel (@Published: duration, elapsed, isRunning, isFlipping, isComplete, particleCount, particleSizeMultiplier, physicsMode, randomColors)
    |
    +-- ContentView overlay (top-left: color toggle;
    |                         top-right: mode picker + particle slider + size slider;
    |                         bottom-left: readout; bottom-right: duration + start/reset)
    |
    +-- HourglassSceneView (UIViewRepresentable)
            +-- Coordinator (tracks physicsMode, isFlipping, wasRunning, particleCount, sizeMultiplier)
                    +-- HourglassScene
                            +-- hourglassContainer (rotates during flip)
                            |   +-- glass (dynamic neck, rebuilt on count change)
                            |   +-- caps
                            |   +-- particlesContainer + N sphere nodes (CPU/GPU)
                            |   +-- rendererNode with icosahedron mesh geometry (Metal only)
                            +-- camera + lights (fixed)
                            +-- GranularSimulation (CPU) OR MetalPhysicsEngine (GPU/Metal)
```

### Lighting

5-point rig (deliberately low intensity to let sand colour show): warm key from upper right (120 intensity, 5000K, casts shadows), front fill from camera direction (100, 4500K), cool side fill from left (60, 6500K), rim light from behind (60, 5500K), omni bottom fill (8, 4500K). Gradient environment map (intensity 0.08). Bloom disabled (intensity 0). All particle materials use **Lambert** lighting model (no specular/Fresnel) to prevent white blowout on particle undersides from reflected light.

### Camera

Fixed perspective: FOV 40°, positioned at (0, 0.05, 3.0), looking at (0, -0.02, 0). Hourglass fills approximately half the screen height. HDR enabled (bloom off, **exposure locked at EV 4**: `minimumExposure = 4`, `maximumExposure = 4`, adaptation speeds set to 100 to prevent gradual brightness shift on startup), depth of field (f/11.0, focus at 3.0m, `motionBlurIntensity = 0`), and screen-space ambient occlusion.

## Key Geometry Functions (SandGeometry.swift)

| Function | Purpose |
|----------|---------|
| `createRevolutionSurface()` | Rotates 2D profile around Y axis with computed normals |
| `setNeckRadius(_:)` | Rebuilds active glass profiles with custom neck width for particle size |
| `innerRadiusAt(y:)` | Looks up inner glass radius at any Y height from the active interpolated profile |
| `createPileWithSpread()` | Unified pile mesh — min(cone slope, glass profile) per ring (legacy, unused) |
| `createSandBody()` | Solid fill conforming to inner glass profile (legacy, unused) |
| `createConcaveBowl()` | Parabolic bowl surface (legacy, unused) |

## App Icons

Generated programmatically with **Python/Pillow** (`generate_icons.py`), not designed in a graphics tool. Three variants at 1024×1024 RGB:

- **Standard** (`hourglass_icon.png`) — warm dark purple-grey (#26243A) background
- **Dark** (`hourglass_icon_dark.png`) — deep charcoal (#1A1A2E) background
- **Tinted** (`hourglass_icon_tinted.png`) — greyscale on near-black (#1C1C1C)

All three share the same design: the exact hourglass Catmull-Rom profile from `SandGeometry.swift`, rendered as a 2D silhouette with glass edge outlines, a specular highlight on the right side, warm wooden caps at top and bottom, and hex-packed golden sand balls settled in a shallow layer at the bottom of the lower chamber — matching the app's resting state. 3× supersampling with LANCZOS downscale for clean anti-aliasing.

Referenced in `Assets.xcassets/AppIcon.appiconset/Contents.json` with `luminosity` appearance variants (standard, dark, tinted).

To regenerate: `python3 generate_icons.py`

## Gotchas

- **Miniature-scale gravity** — the hourglass is ~1 unit tall; real gravity (9.8 m/s²) makes particles traverse it in ~0.3 seconds, invisible to the eye. Gravity scales inversely with duration: `gravityScale = max(5.0 / duration, 0.15)` — full gravity (1.0) at 5s, ~0.17 at 30s. Flow rate controlled by gravity scaling + neck friction
- **Dual glass surfaces double the opacity** — inner glass must be invisible (`opacity = 0.0`); keep it only for its physics body
- **PBR glass is too bright** — environment reflections add brightness independent of transparency. Use Blinn lighting model with low diffuse alpha for subtle glass
- **`writesToDepthBuffer = false`** is required for glass material, otherwise it occludes particles behind it
- **ProMotion** — set `preferredFramesPerSecond = 120` explicitly; SceneKit defaults to 60fps
- **SceneKit startup fade** — set `scnView.backgroundColor = .clear` and `scnView.isPlaying = true` in `makeUIView`, plus `scnView.prepare(scene, shouldAbortBlock: { false })` for synchronous shader compilation, to eliminate the default white-to-scene fade-in on launch
- **Jittering disabled** — `isJitteringEnabled = false`. SceneKit jittering (temporal AA) causes visible blur through the transparent glass when particles are making micro-movements during settling. `multisampling4X` provides sufficient anti-aliasing without temporal artifacts
- **`concavePolyhedron` physics shape** — required for inner glass collider (convex hull won't work for hourglass shape), but expensive; only use on static/kinematic bodies
- **Hourglass symmetry** — glass and caps are symmetric about Y=0, so 180° rotation produces an identical shape; the flip animation exploits this by snapping `eulerAngles` back to (0,0,0) after the rotation
- **SCNAction completion runs on SceneKit thread** — dispatch `completeFlip()` back to main actor via `Task { @MainActor in }` to avoid data races with `@Published` properties
- **Two-phase start** — `startFlip()` and `completeFlip()` are separate because the 1.2s flip animation must complete before the timer starts counting
- **`presentation.eulerAngles.x`** — must use `.presentation` (not `.eulerAngles`) to get the current in-flight animation value during the flip. The model property shows the target, not the current interpolated value
- **Snap-back transform** — after flip, `(x,y,z)→(x,-y,-z)` and `(vx,vy,vz)→(vx,-vy,-vz)` because rotation by pi around X maps Y→-Y, Z→-Z. Glass Y-symmetry means collision profile unchanged. GPU/Metal `snapAfterFlip` also resets all sleep counters to 0
- **CPU capped at 250, GPU at 10000, Metal at 50000** — slider max varies by mode. Each mode stores its particle count independently in UserDefaults. Switching modes recalls that mode's last-used count (or the default: CPU 100, GPU 5000, Metal 10000)
- **Hex-packed spawning** — particles are spawned in hexagonal close-packed layers from the bottom of the lower chamber (up to y=-0.10), producing a near-resting-state configuration. No settling loops needed. Shared `GranularSimulation.packedPositions()` used by both CPU and GPU engines. At low counts the lattice naturally stops well below -0.24 (halfway up lower chamber); at high counts it extends up to -0.10 (still well below neck at y=0). Overflow fallback: when the hex lattice can't fit all particles, remaining particles are placed randomly in the lower chamber (y=-0.48 to -0.10) — never near the neck or in the upper chamber. This prevents stuck particles and ensures all spawns are in the lower chamber
- **Per-mode settings persistence** — `physicsMode`, per-mode `particleCount`, and per-mode `particleSizeMultiplier` are saved to UserDefaults on change and restored in `TimerViewModel.init()`. Each mode has its own keys (`particleCount_CPU`, `particleSize_CPU`, etc.). Defaults: GPU mode, 5000 particles, 1.0× size
- **Duration persistence** — duration is persisted in UserDefaults (key `"timerDuration"`), defaulting to 5s. Valid range 5-30. Uses the same `_duration = Published(initialValue:)` pattern as particleCount in `TimerViewModel.init()`
- **Random colors persistence** — `randomColors` is persisted in UserDefaults (key `"randomColors"`), defaulting to false. Uses `@Published var randomColors: Bool` in TimerViewModel
- **dt clamping** — cap frame delta to 1/30s to prevent physics explosion on frame drops (backgrounding, notification overlay, etc.)
- **Deferred slider application** — particle count and size slider changes do NOT immediately rebuild particles. The ViewModel stores the new value (and persists to UserDefaults), but particles are only rebuilt at three trigger points: (1) flip start — `updateUIView` detects divergence and re-setups before flipping, (2) reset — the reset detection code re-setups with current values, (3) mode change — the mode change code re-setups with current values. This prevents UI freezes from rapid particle rebuilds during slider drag
- **Particle size multiplier** — `particleSizeMultiplier` (0.5–1.5, default 1.0) scales the output of `radiusForCount()`. At 0.5×: thin layer at bottom. At 1.5×: fills roughly half the lower chamber. Neck width auto-adjusts since it's computed from final radius. Persisted per mode via `"particleSize_\(mode.rawValue)"`
- **Rejection sampling replaced by overflow fallback** — the hex lattice packs particles without overlap checking. When count exceeds lattice capacity (hex lattice extends up to y=-0.10), remaining particles are placed randomly in the lower chamber (y=-0.48 to -0.10) where there's room for them to settle via physics
- **Dynamic neck rebuilds glass** — both `setupGranularParticles` and `setupMetalParticles` call `SandGeometry.setNeckRadius()` then `rebuildGlass()`. The active inner profile stored as a static var ensures `innerRadiusAt(y:)` and the GPU profile lookup table both use the updated neck
- **Sand ball material** — Lambert golden sand (0.76/0.60/0.28). Lambert lighting model (no specular/Fresnel) prevents white blowout on particle undersides. Bloom disabled, low lighting intensities, glass specular alpha 0.15 to let the golden colour show
- **Random colors** — when `randomColors` is enabled: CPU/GPU modes use a **24-color palette** of shared SCNSphere geometries (HSB: 24 evenly-spaced hues, 0.7 saturation, 0.85 brightness, Lambert material). Nodes are assigned `geometry = palette[i % 24]`, allowing SceneKit to batch ~N/24 nodes per draw call instead of N individual draw calls (major GPU performance improvement). Metal mode uses per-vertex colors via the expanded `MeshVertex` struct (28 bytes: `packed_float3` pos + `packed_float3` normal + `uchar4` color). `MetalPhysicsEngine` maintains a color buffer (one `uchar4` per particle). The `expandMeshes` kernel copies each particle's color to all 42 of its vertices. `SCNGeometrySource` with `.color` semantic provides vertex colors to SceneKit. Material diffuse is set to `UIColor(white: 0.78)` (not white) to match perceived brightness of CPU/GPU sphere nodes
- **Thread safety** — `HourglassScene` uses `NSLock` to protect particle state from concurrent access between SceneKit render thread and main thread. `readPositions()` returns a safe `[GPUParticle]` copy, not an `UnsafeBufferPointer`, preventing dangling pointer crashes during teardown
- **Neck friction** — `neckDamping = duration * 0.02`, applied in a zone where `|y| < 0.10`. Particles near the neck get extra velocity damping, scaling linearly toward the centre. Works alongside gravity scaling (`gravityScale = max(5.0 / duration, 0.15)`) to control flow rate. Both CPU and GPU engines have `neckDamping`/`neckHalfHeight` and `gravity` properties; GPU passes them as uniforms
- **Coordinator init vs @MainActor** — Coordinator is `NSObject` (nonisolated), so its `init` cannot access `@MainActor` properties from the ViewModel. Initial particle setup happens in `makeUIView` instead
- **Metal double-buffering** — read from buffer A, write to buffer B, swap per substep. Avoids race conditions in parallel collision resolution. Each thread only modifies its own particle
- **Chamber-asymmetric GPU collision** — lower chamber: 0.25 position correction + 0.25 impulse for all approaching contacts (transmits pile normal force chain). Upper chamber: 0.25 position correction only, NO impulse (gravity must dominate to drain the pile). Parallel collision impulses cancel gravity in packed piles, causing jamming — discovered via test data showing all upper-chamber velocities at exactly zero
- **GPU profile lookup table** — 256 entries with linear interpolation. Must be rebuilt when neck radius changes (particle count change). Passed as `buffer(2)` to the compute kernel
- **Metal fallback** — `setupMetalParticles` falls back to CPU mode if `MetalPhysicsEngine` init fails (e.g. simulator without Metal support)
- **Active controls with deferred sliders** — top-right controls (mode picker, size slider, count slider) are always enabled. Mode changes during animation trigger instant restart via `onChange` → `viewModel.restart()`. Count/size slider changes are **deferred** — `updateUIView` only applies them when idle (not running/flipping). Every flip start unconditionally rebuilds particles with the current values (not just when divergence detected). This prevents freezing from rapid particle rebuilds during slider drag while ensuring clean spawn state. The `startFlip()` method handles being called while running by cancelling the in-flight timer first
- **Buffer reallocation** — `MetalPhysicsEngine.resetToBottom` checks if existing buffers are large enough before reallocating. Avoids unnecessary allocation when count decreases
- **Metal mode mesh expansion** — `expandMeshes()` compute kernel generates subdivided icosahedron vertices (42 per particle, 80 faces) from particle positions. Each vertex is a 28-byte `MeshVertex` (pos + normal + color). `SCNGeometrySource(buffer:)` wraps the expanded vertex buffer with separate sources for position, normal, and color semantics. Index buffer is pre-computed and static. Geometry is created ONCE during `setupInstancedParticles` and reused — SceneKit re-reads the updated MTLBuffer each frame automatically. Rebuilding geometry per frame causes visible flicker because SceneKit briefly invalidates the old geometry before the new one is ready. Explicit bounding box on the renderer node prevents SceneKit from recomputing bounds from vertex data each frame
- **O(N²) collision always on** — collision is never skipped. Max particle counts (CPU 250, GPU 10k, Metal 50k) are set to keep O(N²) feasible at interactive frame rates. At 50k with 1 substep, each thread does ~50k comparisons per frame
- **Subdivided icosahedron mesh for Metal mode** — point primitives lack surface normals (produce dark/invisible particles). Mesh expansion generates subdivided icosahedron vertices (42 verts, 80 faces) with proper normals, enabling full Lambert lighting. All 42 vertices lie on the unit sphere so the mesh closely approximates a sphere — no radius scaling correction needed (unlike the previous octahedron which needed √3 scaling). The visual appearance closely matches CPU/GPU mode spheres
- **Two-tier sleep system (GPU/Metal, lower chamber only, contact-based)** — `velocityAndPad.w` stores a sleep counter. Only increments in the lower chamber (pos.y < 0) when speed < 0.08 AND `hasSupport` (contactCount > 0) — generous threshold catches surface oscillation at ~0.05 from parallel collision. Free-falling particles (zero contacts) always reset to counter 0, preventing mid-air freeze. Upper-chamber particles always have counter = 0 (must stay awake to drain). Counter 16-30: "light sleep" — O(N) wake-up check, wakes only if a non-sleeping neighbor is approaching fast (`relVelNormal < -0.05`). `sleepContactCount` was removed from light sleep — it caused oscillation/blur through the glass (particles barely separated from neighbors woke every ~15 frames). Support-loss detection is deferred to the deep sleep staggered check. Counter >30: "deep sleep" — **staggered support check** every 30 frames (offset by thread ID): floor contact counts as support (cheap check, no neighbor scan), otherwise scans for nearby particles within 1.05x touching distance; if no support found, particle wakes and falls within ~0.5s. Staggering keeps deep sleep nearly free (~N/30 checks per frame instead of N). `snapAfterFlip` resets all counters to 0. CPU mode doesn't need sleep — sequential collision converges naturally
- **Chamber-dependent damping (GPU/Metal)** — upper chamber: flow-only damping (`pow(0.92, subDt)`) preserves gravity's effect so the pile drains. Lower chamber: blends between flow (0.92) and aggressive settle (0.05) based on speed (threshold 0.15). CPU uses the same settle blend everywhere (works because sequential resolution converges)
- **Velocity cutoff (GPU/Metal, lower chamber only, contact-based)** — if `length(vel) < 0.01` AND `hasSupport` (contactCount > 0), velocity snapped to zero. Only in lower chamber — upper chamber must accumulate tiny gravity increments to drain. The `contactCount` check prevents mid-air particle suspension: free-falling particles with zero contacts never have velocity zeroed. `contactCount` is tracked during the O(N²) collision loop (incremented for each overlapping pair). This also gates sleep entry — only particles resting on other particles or the floor can enter sleep
- **Metal flip animation** — renderer node is child of `hourglassContainer`, so container rotation is included in the transform. After snap-back, `snapAfterFlip()` transforms buffer data and the next frame renders updated positions automatically
- **SCNNodeRendererDelegate doesn't work** — the original Metal instanced plan used `SCNNodeRendererDelegate` with custom `drawIndexedPrimitives` calls, but extensive testing confirmed these produce no visible pixels in SceneKit's multi-pass rendering. The mesh expansion approach (`SCNGeometrySource(buffer:)` + `.triangles` elements) works reliably through SceneKit's standard pipeline
- **Reset respawns, completion does not** — manual Reset respawns all particles at the bottom via `setup*Particles`. Natural timer completion leaves particles at rest where they settled. Flip start only rebuilds if count/size/color changed since last setup. This prevents visual jumps (particles snapping to hex-packed state) when transitioning between runs
- **HDR auto-exposure locked** — `camera.minimumExposure = 4`, `camera.maximumExposure = 4`, adaptation speeds set to 100. Without this, SceneKit's HDR pipeline gradually brightens the scene over ~2 minutes as it adapts to scene luminance. EV 4 matches the fully-adapted brightness level
- **CLI args** — command line arguments processed in `ContentView.onAppear`: `-mode cpu|gpu|metal` (override physics mode), `-count N` (override particle count), `-size F` (override size multiplier), `-dumpspawn` (dump spawn state histogram to Documents/spawn_state.txt after 2s delay). Mode must be set before count/size because mode's `didSet` recalls saved count. `-test`, `-autostart`, and `-multicolor` also supported
- **`TimerViewModel.dumpSpawnState()`** — public method that reads particle positions from `MetalPhysicsEngine`, computes upper/lower/neck counts and Y histogram (20 bins from -0.50 to 0.50), writes to Documents/spawn_state.txt via NSLog. Requires `sceneRef` (weak ref to HourglassScene) to be set by the Coordinator
- **Packing correction in radiusForCount** — the base formula `r ∝ N^(-1/3)` keeps total sphere volume constant, but smaller particles leave more wall clearance so each hex-packed layer holds more particles and the pile is shorter. A correction factor `(effR / refEffR)^(2/3)` scales radius up at high counts to maintain the same visual fill height as the 250-particle reference
