import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = TimerViewModel()

    private var isIdle: Bool {
        !viewModel.isRunning && !viewModel.isFlipping
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 3D hourglass scene (full screen)
            HourglassSceneView(viewModel: viewModel)
                .ignoresSafeArea()

            // Top-left: color toggle
            VStack {
                HStack {
                    Toggle("Colors", isOn: $viewModel.randomColors)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .tint(.white.opacity(0.5))
                        .frame(width: 140)
                        .padding(.leading, 24)
                        .padding(.top, 8)
                    Spacer()
                }
                Spacer()
            }

            // Top-right: physics mode + particle count
            VStack {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Picker("Physics", selection: $viewModel.physicsMode) {
                            ForEach(TimerViewModel.PhysicsMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)

                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Size: \(sizeLabel)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))

                            Slider(
                                value: $viewModel.particleSizeMultiplier,
                                in: 0.5...1.5,
                                step: 0.05
                            )
                            .frame(width: 160)
                            .tint(.white.opacity(0.5))
                        }

                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(particleCountLabel) particles")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))

                            Slider(
                                value: Binding(
                                    get: { Double(viewModel.particleCount) },
                                    set: { viewModel.particleCount = Int($0) }
                                ),
                                in: 50...Double(viewModel.physicsMode.maxParticles),
                                step: 50
                            )
                            .frame(width: 160)
                            .tint(.white.opacity(0.5))
                        }
                    }
                    .padding(.trailing, 24)
                    .padding(.top, 8)
                }
                Spacer()
            }

            // Bottom-left: time remaining readout
            VStack {
                Spacer()
                HStack {
                    Text(viewModel.remainingText)
                        .font(.system(size: 48, weight: .ultraLight, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
                        .padding(.leading, 24)
                        .padding(.bottom, 50)
                    Spacer()
                }
            }

            // Bottom-right: duration controls + start/reset
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: 12) {
                        // Duration controls
                        VStack(alignment: .trailing, spacing: 6) {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(durationLabel)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))

                                Slider(
                                    value: $viewModel.duration,
                                    in: 5...30,
                                    step: 5
                                )
                                .frame(width: 160)
                                .tint(.white.opacity(0.5))
                                .disabled(!isIdle)
                            }

                            HStack(spacing: 8) {
                                ForEach(TimerViewModel.presets, id: \.1) { name, duration in
                                    presetButton(name: name, duration: duration)
                                }
                            }
                            .disabled(!isIdle)
                        }

                        // Start / Reset button
                        Button {
                            if viewModel.isRunning || viewModel.isFlipping {
                                viewModel.reset()
                            } else {
                                if viewModel.isComplete { viewModel.reset() }
                                viewModel.startFlip()
                            }
                        } label: {
                            Text(buttonLabel)
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 120, height: 48)
                                .background(Color.white.opacity(0.2))
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.trailing, 24)
                    .padding(.bottom, 50)
                }
            }
        }
        .onChange(of: viewModel.physicsMode) {
            if viewModel.isRunning || viewModel.isFlipping {
                viewModel.restart()
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear {
            let args = CommandLine.arguments
            if args.contains("-multicolor") {
                viewModel.randomColors = true
            }
            // CLI overrides: mode first (its didSet recalls saved count),
            // then count/size override after
            if let idx = args.firstIndex(of: "-mode"), idx + 1 < args.count {
                switch args[idx + 1].lowercased() {
                case "cpu": viewModel.physicsMode = .cpu
                case "gpu": viewModel.physicsMode = .gpu
                case "metal": viewModel.physicsMode = .metal
                default: break
                }
            }
            if let idx = args.firstIndex(of: "-count"), idx + 1 < args.count,
               let count = Int(args[idx + 1]) {
                viewModel.particleCount = count
            }
            if let idx = args.firstIndex(of: "-size"), idx + 1 < args.count,
               let size = Float(args[idx + 1]) {
                viewModel.particleSizeMultiplier = size
            }
            if args.contains("-dumpspawn") {
                viewModel.testMode = true
                // Dump spawn state after a brief delay for setup to complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    viewModel.dumpSpawnState()
                }
            }
            if args.contains("-test") {
                // Test mode: 10s duration, auto-start, dump results on completion
                viewModel.duration = 10
                viewModel.testMode = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    viewModel.startFlip()
                }
            } else if args.contains("-autostart") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    viewModel.startFlip()
                }
            }
        }
    }

    private var particleCountLabel: String {
        let count = viewModel.particleCount
        if count >= 1000 {
            let k = Double(count) / 1000.0
            if count % 1000 == 0 {
                return "\(Int(k))k"
            } else {
                return String(format: "%.1fk", k)
            }
        }
        return "\(count)"
    }

    private var sizeLabel: String {
        String(format: "%.2fx", viewModel.particleSizeMultiplier)
    }

    private var durationLabel: String {
        let total = Int(viewModel.duration)
        let minutes = total / 60
        let seconds = total % 60
        if minutes > 0 && seconds > 0 {
            return "\(minutes)m \(seconds)s"
        } else if minutes > 0 {
            return "\(minutes) min"
        } else {
            return "\(seconds)s"
        }
    }

    private var buttonLabel: String {
        if viewModel.isFlipping { return "Reset" }
        if viewModel.isRunning { return "Reset" }
        return "Start"
    }

    private func presetButton(name: String, duration: TimeInterval) -> some View {
        Button(name) {
            viewModel.duration = duration
            viewModel.reset()
        }
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            viewModel.duration == duration
                ? Color.white.opacity(0.3)
                : Color.white.opacity(0.1)
        )
        .foregroundStyle(.white)
        .clipShape(Capsule())
    }
}
