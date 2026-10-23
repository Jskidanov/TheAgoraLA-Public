import SwiftUI

struct InteractivePromptView: View {
    let prompt: Prompt
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var pointsStore: PointsStore

    var body: some View {
        AgoraCard {
            VStack(spacing: 16) {
                HStack(spacing: 10) {
                    if let position = viewModel.activePromptPosition {
                        Text("\(position.number)")
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.inkOnAccent)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(promptAccentGradient))
                            .accessibilityLabel("Question \(position.number) of \(position.total)")
                    }

                    Text("Agora Check-In")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)

                    Spacer()

                    AgoraTag(text: "Live")
                }

                Text(prompt.question)
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Response")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)

                    TextEditor(text: $viewModel.answerText)
                        .scrollContentBackground(.hidden)
                        .foregroundColor(AgoraTheme.ink)
                        .background(Color.clear)
                        .frame(height: 120)
                        .padding(10)
                        .background(Color.white.opacity(0.8))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                        )
                        .disabled(
                            viewModel.drivingModeEnabled
                                && (viewModel.drivingPromptState == .listening
                                    || viewModel.drivingPromptState == .submitting)
                        )
                }

                if viewModel.drivingModeEnabled {
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: handsFreeStatusIcon)
                                .foregroundColor(promptAccent)
                            Text("Complete Hands-Free")
                                .font(AgoraTheme.cardTitleFont)
                                .foregroundColor(AgoraTheme.ink)
                        }

                        if !viewModel.drivingStatusText.isEmpty {
                            Text(viewModel.drivingStatusText)
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                        }

                        if viewModel.drivingPromptState == .listening {
                            VStack(spacing: 6) {
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(AgoraTheme.inkMuted.opacity(0.14))
                                        Capsule()
                                            .fill(promptAccentGradient)
                                            .frame(
                                                width: max(
                                                    8,
                                                    geometry.size.width * viewModel.speechManager.inputLevel
                                                )
                                            )
                                    }
                                }
                                .frame(height: 8)
                                .animation(
                                    .linear(duration: 0.08),
                                    value: viewModel.speechManager.inputLevel
                                )
                                .accessibilityLabel("Microphone input level")
                                .accessibilityValue(
                                    viewModel.speechManager.hasDetectedVoice
                                        ? "Voice detected"
                                        : "Waiting for speech"
                                )

                                Text(
                                    viewModel.speechManager.hasDetectedVoice
                                        ? "Voice detected. Submit is automatic when you finish."
                                        : "Start speaking when you are ready."
                                )
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                            }
                            .transition(.opacity)
                        }

                        if viewModel.drivingPromptState == .speakingFeedback {
                            Button {
                                viewModel.stopFeedbackNarration()
                            } label: {
                                Label("Stop Feedback", systemImage: "stop.fill")
                                    .font(AgoraTheme.bodyFont.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(AgoraOutlineButtonStyle())
                            .accessibilityHint("Stops the narrator and keeps the written feedback on screen")
                        } else {
                            if viewModel.hasScoredActivePrompt, viewModel.drivingPromptState == .idle {
                                Button("Read Feedback") { viewModel.replayFeedbackNarration() }
                                    .buttonStyle(AgoraOutlineButtonStyle())
                            }
                            Button {
                                viewModel.drivingMicTapped()
                            } label: {
                                Image(systemName: isHandsFreeListening ? "stop.fill" : "mic.fill")
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundColor(AgoraTheme.inkOnAccent)
                                    .frame(width: 110, height: 110)
                                    .background(Circle().fill(promptAccentGradient))
                                    .shadow(color: AgoraTheme.shadow, radius: 10, x: 0, y: 6)
                            }
                            .disabled(!viewModel.canUseDrivingMicrophone)
                            .accessibilityLabel(
                                isHandsFreeListening
                                    ? "Stop recording"
                                    : "Read the question and start answering"
                            )
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        Button(viewModel.speechManager.isRecording ? "Stop" : "Speak") {
                            viewModel.toggleRecording()
                        }
                        .buttonStyle(AgoraOutlineButtonStyle())

                        Button("Use Transcript") {
                            viewModel.answerText = viewModel.speechManager.transcript
                        }
                        .buttonStyle(AgoraOutlineButtonStyle())
                    }
                }

                if viewModel.isEvaluating {
                    ProgressView("Evaluating...")
                        .font(AgoraTheme.bodyFont)
                }

                if !viewModel.feedbackText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Score")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)

                            Spacer()

                            Text("\(viewModel.lastScore)/100")
                                .font(AgoraTheme.cardTitleFont)
                                .foregroundColor(AgoraTheme.ink)
                        }

                        HStack {
                            Text("Grade \(viewModel.lastGrade.rawValue)")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                            Spacer()
                            Text("\(viewModel.lastAwardedPoints) Agora Points earned")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                        }

                        AgoraExpandableText(
                            text: viewModel.feedbackText,
                            collapsedLineLimit: viewModel.feedbackDetailLevel == .quick ? 3 : 7,
                            expansionThreshold: 320
                        )

                        if viewModel.feedbackDetailLevel != .quick {
                            Divider()

                            Text("Podcast-supported answer")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                            AgoraExpandableText(
                                text: prompt.expectedAnswer,
                                collapsedLineLimit: 5,
                                expansionThreshold: 240,
                                color: AgoraTheme.ink
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button("Submit") {
                        Task {
                            await viewModel.submitAnswer(pointsStore: pointsStore)
                        }
                    }
                    .buttonStyle(AgoraPillButtonStyle())
                    .disabled(
                        (viewModel.drivingModeEnabled && viewModel.drivingPromptState != .idle)
                            || viewModel.isEvaluating
                            || !viewModel.canSubmitActiveAnswer
                    )

                    Button("Continue") {
                        viewModel.continuePlayback()
                    }
                    .buttonStyle(AgoraOutlineButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .onChange(of: viewModel.answerText) { _ in
            viewModel.activeAnswerDidChange()
        }
    }

    private var promptAccent: Color {
        viewModel.drivingModeEnabled ? AgoraTheme.handsFreeAccent : AgoraTheme.accent
    }

    private var promptAccentGradient: LinearGradient {
        viewModel.drivingModeEnabled ? AgoraTheme.handsFreeAccentGradient : AgoraTheme.accentGradient
    }

    private var handsFreeStatusIcon: String {
        switch viewModel.drivingPromptState {
        case .listening:
            return "waveform"
        case .submitting:
            return "sparkles"
        case .announcingPrompt, .speakingFeedback, .retryingListening:
            return "speaker.wave.2.fill"
        case .idle:
            return "waveform.and.mic"
        }
    }

    private var isHandsFreeListening: Bool {
        viewModel.drivingPromptState == .listening
    }
}
