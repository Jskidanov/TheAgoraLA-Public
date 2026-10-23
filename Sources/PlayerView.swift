import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @EnvironmentObject private var pointsStore: PointsStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var scrubPosition = 0.0
    @State private var isScrubbing = false
    @State private var showHandsFreePermissionAlert = false

    var body: some View {
        VStack(spacing: 16) {
            AgoraCard {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Now Playing")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)

                        Text(viewModel.episode.title)
                            .font(AgoraTheme.cardValueFont)
                            .foregroundColor(AgoraTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 8) {
                        PodcastProgressSlider(
                            tintColor: playerAccent,
                            value: Binding(
                                get: { isScrubbing ? scrubPosition : viewModel.currentTime },
                                set: { scrubPosition = $0 }
                            ),
                            range: 0...max(viewModel.duration, 1),
                            onEditingChanged: { editing in
                                if editing {
                                    scrubPosition = viewModel.currentTime
                                    isScrubbing = true
                                } else {
                                    viewModel.seek(to: scrubPosition)
                                    isScrubbing = false
                                }
                            }
                        )
                            .frame(height: 32)
                            .accessibilityLabel("Episode position")
                            .accessibilityValue(formatTime(isScrubbing ? scrubPosition : viewModel.currentTime))

                        HStack {
                            Text(formatTime(isScrubbing ? scrubPosition : viewModel.currentTime))
                            Spacer()
                            Text(formatTime(viewModel.duration))
                        }
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                    }

                    if let playbackError = viewModel.audioManager.playbackError {
                        Text(playbackError)
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if viewModel.audioManager.isBuffering {
                        ProgressView("Buffering audio...")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(spacing: 16) {
                        Button {
                            viewModel.skip(by: -15)
                        } label: {
                            Image(systemName: "gobackward.15")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 48, height: 48)
                                .background(
                                    Circle().fill(AgoraTheme.cardSurface)
                                )
                                .foregroundColor(AgoraTheme.ink)
                                .overlay(
                                    Circle().stroke(AgoraTheme.cardStroke, lineWidth: 1)
                                )
                        }

                        Button {
                            viewModel.togglePlay()
                        } label: {
                            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 56, height: 56)
                                .background(
                                    Circle().fill(playerAccentGradient)
                                )
                                .foregroundColor(AgoraTheme.inkOnAccent)
                                .shadow(color: AgoraTheme.shadow, radius: 8, x: 0, y: 4)
                        }
                        .disabled(viewModel.showPrompt)
                        .opacity(viewModel.showPrompt ? 0.5 : 1)
                        .accessibilityLabel(viewModel.isPlaying ? "Pause podcast" : "Play podcast")
                        .accessibilityHint(viewModel.showPrompt ? "Use Continue in the check-in to resume the podcast." : "")

                        Button {
                            viewModel.skip(by: 15)
                        } label: {
                            Image(systemName: "goforward.15")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 48, height: 48)
                                .background(
                                    Circle().fill(AgoraTheme.cardSurface)
                                )
                                .foregroundColor(AgoraTheme.ink)
                                .overlay(
                                    Circle().stroke(AgoraTheme.cardStroke, lineWidth: 1)
                                )
                        }
                    }

                    Divider()

                    HStack(spacing: 12) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(playerAccent)
                            .frame(width: 30)

                        Text("Complete Hands-Free")
                            .font(AgoraTheme.bodyFont)
                            .foregroundColor(AgoraTheme.ink)
                        Spacer(minLength: 8)

                        Toggle(
                            "Complete Hands-Free",
                            isOn: Binding(
                                get: { viewModel.drivingModeEnabled },
                                set: { viewModel.setHandsFreeMode($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: playerAccent))
                        .accessibilityLabel("Complete Hands-Free")
                    }
                }
            }
            .animation(.easeInOut(duration: 0.4), value: viewModel.drivingModeEnabled)
            .padding(.horizontal, 16)

            if viewModel.showPrompt, let prompt = viewModel.activePrompt {
                InteractivePromptView(
                    prompt: prompt,
                    viewModel: viewModel,
                    pointsStore: pointsStore
                )
            }

            if !viewModel.queuedPrompts.isEmpty {
                promptQueue
            }
        }
        .onReceive(viewModel.audioManager.$currentTime) { time in
            viewModel.checkForPrompt(at: time)
        }
        .task {
            viewModel.bind(pointsStore: pointsStore)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                viewModel.appDidBecomeActive()
            case .inactive, .background:
                viewModel.appDidEnterBackground()
            @unknown default:
                break
            }
        }
        .onChange(of: viewModel.handsFreeNeedsSettings) { needsSettings in
            showHandsFreePermissionAlert = needsSettings
        }
        .alert("Hands-Free Needs Permission", isPresented: $showHandsFreePermissionAlert) {
            #if canImport(UIKit)
            Button("Open Settings") {
                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                openURL(settingsURL)
            }
            #endif
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Allow Microphone and Speech Recognition access to use Complete Hands-Free.")
        }
    }

    private var promptQueue: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(viewModel.showPrompt ? "Earlier Check-Ins" : "Your Check-Ins")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)
                    Spacer()
                    AgoraTag(text: "\(viewModel.queuedPrompts.count)")
                }

                ForEach(Array(viewModel.queuedPrompts.enumerated()), id: \.element.id) { index, prompt in
                    Button {
                        viewModel.presentPrompt(prompt)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: viewModel.response(for: prompt)?.score == nil
                                  ? "questionmark.circle"
                                  : "checkmark.circle.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(playerAccent)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(index == 0 && !viewModel.showPrompt ? "Most Recent" : "Previous Prompt")
                                        .font(AgoraTheme.tagFont)
                                        .foregroundColor(AgoraTheme.inkMuted)

                                    Text(formatTime(prompt.timestampSeconds))
                                        .font(AgoraTheme.tagFont)
                                        .foregroundColor(AgoraTheme.inkMuted)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(AgoraTheme.tagBackground))
                                        .accessibilityLabel("Asked at \(formatTime(prompt.timestampSeconds))")
                                }
                                Text(prompt.question)
                                    .font(AgoraTheme.bodyFont)
                                    .foregroundColor(AgoraTheme.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)

                                if let response = viewModel.response(for: prompt) {
                                    Text(response.score.map { "Score \($0)/100 - Tap to review or revise" }
                                         ?? "Draft saved - Tap to continue")
                                        .font(AgoraTheme.tagFont)
                                        .foregroundColor(AgoraTheme.inkMuted)
                                } else {
                                    Text("Tap to answer")
                                        .font(AgoraTheme.tagFont)
                                        .foregroundColor(AgoraTheme.inkMuted)
                                }
                            }

                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(AgoraTheme.inkMuted)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < viewModel.queuedPrompts.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let intSeconds = Int(seconds)
        let minutes = intSeconds / 60
        let remainingSeconds = intSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    /// Complete Hands-Free repaints the Now Playing controls; the rest of the
    /// app keeps the fixed brand accent.
    private var playerAccent: Color {
        viewModel.drivingModeEnabled ? AgoraTheme.handsFreeAccent : AgoraTheme.accent
    }

    private var playerAccentGradient: LinearGradient {
        viewModel.drivingModeEnabled ? AgoraTheme.handsFreeAccentGradient : AgoraTheme.accentGradient
    }

}

#if canImport(UIKit)
private struct PodcastProgressSlider: UIViewRepresentable {
    let tintColor: Color
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, onEditingChanged: onEditingChanged)
    }

    func makeUIView(context: Context) -> PodcastUISlider {
        let slider = PodcastUISlider(frame: .zero)
        slider.isContinuous = true
        slider.minimumTrackTintColor = UIColor(tintColor)
        slider.maximumTrackTintColor = UIColor(AgoraTheme.progressTrack)
        slider.thumbTintColor = .white
        slider.addTarget(context.coordinator, action: #selector(Coordinator.editingBegan(_:)), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingEnded(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        return slider
    }

    func updateUIView(_ slider: PodcastUISlider, context: Context) {
        context.coordinator.value = $value
        context.coordinator.onEditingChanged = onEditingChanged
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        UIView.animate(withDuration: 0.4) {
            slider.minimumTrackTintColor = UIColor(tintColor)
        }
        slider.maximumTrackTintColor = UIColor(AgoraTheme.progressTrack)
        if !slider.isTracking {
            slider.setValue(Float(min(max(value, range.lowerBound), range.upperBound)), animated: false)
        }
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        var onEditingChanged: (Bool) -> Void

        init(value: Binding<Double>, onEditingChanged: @escaping (Bool) -> Void) {
            self.value = value
            self.onEditingChanged = onEditingChanged
        }

        @objc func editingBegan(_ slider: UISlider) {
            onEditingChanged(true)
        }

        @objc func valueChanged(_ slider: UISlider) {
            value.wrappedValue = Double(slider.value)
        }

        @objc func editingEnded(_ slider: UISlider) {
            value.wrappedValue = Double(slider.value)
            onEditingChanged(false)
        }
    }
}

private final class PodcastUISlider: UISlider {
    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        let defaultRect = super.trackRect(forBounds: bounds)
        return CGRect(x: defaultRect.minX, y: bounds.midY - 2, width: defaultRect.width, height: 4)
    }
}
#endif

struct PlaybackSettingsView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationView {
            ZStack {
                AgoraBackgroundView()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        interactiveSettings
                        handsFreeSettings
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Playback Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(AgoraTheme.accent)
                }
            }
        }
    }

    private var interactiveSettings: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Interactive Prompts")
                    .font(AgoraTheme.cardTitleFont)
                    .foregroundColor(AgoraTheme.ink)

                Text("Pause at the best moments in the episode for AI-guided reflection.")
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)

                Toggle(
                    "Enable Interactive Prompts",
                    isOn: Binding(
                        get: { viewModel.interactiveModeEnabled },
                        set: { viewModel.setInteractiveMode($0) }
                    )
                )
                .font(AgoraTheme.bodyFont)
                .foregroundColor(AgoraTheme.ink)
                .toggleStyle(SwitchToggleStyle(tint: AgoraTheme.accent))

                if viewModel.interactiveModeEnabled {
                    Divider()
                    feedbackDetailControl
                    Divider()
                    answerAnalysisControl
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var feedbackDetailControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feedback After Each Answer")
                .font(AgoraTheme.cardTitleFont)
                .foregroundColor(AgoraTheme.ink)

            Text(feedbackDetailDescription)
                .font(AgoraTheme.tagFont)
                .foregroundColor(AgoraTheme.inkMuted)

            Slider(
                value: Binding(
                    get: { Double(viewModel.feedbackDetailLevel.rawValue) },
                    set: { newValue in
                        viewModel.feedbackDetailLevel = FeedbackDetailLevel(rawValue: Int(newValue.rounded())) ?? .full
                    }
                ),
                in: 0...2,
                step: 1
            )
            .tint(AgoraTheme.accent)
            .accessibilityLabel("Feedback detail")
            .accessibilityValue(feedbackDetailAccessibilityValue)

            HStack {
                Text("Little")
                Spacer()
                Text("Balanced")
                Spacer()
                Text("A Lot")
            }
            .font(AgoraTheme.tagFont)
            .foregroundColor(AgoraTheme.inkMuted)
        }
    }

    private var answerAnalysisControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Analysis Of Your Answers")
                .font(AgoraTheme.cardTitleFont)
                .foregroundColor(AgoraTheme.ink)

            Text(answerAnalysisDescription)
                .font(AgoraTheme.tagFont)
                .foregroundColor(AgoraTheme.inkMuted)

            Slider(
                value: Binding(
                    get: { Double(viewModel.answerAnalysisDepth.rawValue) },
                    set: { newValue in
                        viewModel.answerAnalysisDepth = AnswerAnalysisDepth(rawValue: Int(newValue.rounded())) ?? .deepest
                    }
                ),
                in: 0...2,
                step: 1
            )
            .tint(AgoraTheme.accent)
            .accessibilityLabel("Answer analysis depth")
            .accessibilityValue(answerAnalysisAccessibilityValue)

            HStack {
                Text("Faster")
                Spacer()
                Text("Thorough")
                Spacer()
                Text("Deepest")
            }
            .font(AgoraTheme.tagFont)
            .foregroundColor(AgoraTheme.inkMuted)
        }
    }

    private var handsFreeSettings: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Complete Hands-Free")
                    .font(AgoraTheme.cardTitleFont)
                    .foregroundColor(AgoraTheme.ink)

                Text("Prompts are read aloud. Speak your answer, then hear your score and corrections automatically. Turn this on from the player screen.")
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)

                Text("Say \"Repeat the question,\" \"Start over,\" or \"Skip this question\" at any time.")
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)

                Divider()

                narrationSettings

                #if targetEnvironment(simulator)
                Text("Testing on Mac: in Simulator, choose I/O > Audio Input > Mac microphone.")
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.accent)
                #endif

                if !viewModel.drivingStatusText.isEmpty {
                    Text(viewModel.drivingStatusText)
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(viewModel.drivingModeEnabled ? AgoraTheme.accent : .red)
                }

                if viewModel.handsFreeNeedsSettings {
                    #if canImport(UIKit)
                    Button("Open Privacy Settings") {
                        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(settingsURL)
                    }
                    .buttonStyle(AgoraOutlineButtonStyle())
                    .accessibilityHint("Opens microphone and speech permissions for Agora Interactive Podcast")
                    #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var narrationSettings: some View {
        if let selectedVoice = selectedNarrationVoice {
            VStack(alignment: .leading, spacing: 8) {
                Text("Narrator")
                    .font(AgoraTheme.tagFont.weight(.bold))
                    .foregroundColor(AgoraTheme.ink)

                Menu {
                    ForEach(viewModel.narrationVoiceOptions) { option in
                        Button {
                            viewModel.selectedNarrationVoiceID = option.id
                        } label: {
                            if option.id == viewModel.selectedNarrationVoiceID {
                                Label(option.name, systemImage: "checkmark")
                            } else {
                                Text(option.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text(selectedVoice.name)
                            .font(AgoraTheme.bodyFont.weight(.semibold))
                            .foregroundColor(AgoraTheme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(AgoraTheme.accent)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.68))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                    )
                    .cornerRadius(12)
                }
                .accessibilityLabel("Narrator voice")
                .accessibilityValue(selectedVoice.name)

                Text(selectedVoice.detail)
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)

                HStack(spacing: 16) {
                    Button {
                        viewModel.previewNarrationVoice()
                    } label: {
                        Label("Preview Voice", systemImage: "speaker.wave.2.fill")
                    }
                    .disabled(viewModel.drivingPromptState != .idle)

                    if viewModel.selectedNarrationVoiceID != NarrationVoiceOption.automaticID {
                        Button("Use Natural AI Voice") {
                            viewModel.selectedNarrationVoiceID = NarrationVoiceOption.automaticID
                        }
                    }
                }
                .font(AgoraTheme.tagFont.weight(.semibold))
                .foregroundColor(AgoraTheme.accent)
            }
        }
    }

    private var selectedNarrationVoice: NarrationVoiceOption? {
        viewModel.narrationVoiceOptions.first {
            $0.id == viewModel.selectedNarrationVoiceID
        }
    }

    private var feedbackDetailDescription: String {
        switch viewModel.feedbackDetailLevel {
        case .quick:
            return "Quick: receive your grade and helpful feedback. Hands-free resumes after narration; otherwise tap Continue."
        case .balanced:
            return "Balanced: see your grade, feedback, and the podcast's answer. Hands-free resumes after narration; otherwise tap Continue."
        case .full:
            return "Full: see your grade, feedback, and the podcast's answer. Hands-free resumes after narration; otherwise tap Continue."
        }
    }

    private var feedbackDetailAccessibilityValue: String {
        switch viewModel.feedbackDetailLevel {
        case .quick: return "Little"
        case .balanced: return "Balanced"
        case .full: return "A lot"
        }
    }

    private var answerAnalysisDescription: String {
        switch viewModel.answerAnalysisDepth {
        case .quick:
            return "Faster: your answer is graded with the least waiting, and feedback stays brief."
        case .thorough:
            return "Thorough: the AI weighs your answer more carefully before grading it."
        case .deepest:
            return "Deepest: the AI takes the most time to consider your answer, for the most precise feedback."
        }
    }

    private var answerAnalysisAccessibilityValue: String {
        switch viewModel.answerAnalysisDepth {
        case .quick: return "Faster"
        case .thorough: return "Thorough"
        case .deepest: return "Deepest"
        }
    }
}
