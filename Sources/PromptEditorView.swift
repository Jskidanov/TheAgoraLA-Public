import SwiftUI
import Foundation

private enum PromptEditorError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        "Enter a valid podcast page, public RSS feed, or direct audio link."
    }
}

private struct BrowsedEpisodeSelection {
    let sourceText: String
    let feedURL: URL
    let guid: String?
    let title: String
}

private enum PromptCountMode: String, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case manual = "Manual"

    var id: String { rawValue }
}

struct PromptEditorView: View {
    @ObservedObject var episodeStore: EpisodeStore
    let onResetPromptProgress: (UUID) -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var aiAccount: AIAccountStore
    @State private var newQuestion = ""
    @State private var newAnswer = ""
    @State private var newTimestamp = ""
    @State private var newLeadTime = 0.0
    @State private var audioURLText = ""
    @State private var titleText = ""
    @State private var transcriptText = ""
    @State private var summaryText = ""
    @State private var showInvalidURL = false
    @State private var isResolving = false
    @State private var importStatusText = ""
    @State private var isPreparingTranscript = false
    @State private var analysisErrorMessage = ""
    @State private var showAnalysisError = false
    @State private var showProviderCreditsAction = false
    @State private var transcriptExpanded = false
    @State private var selectedPromptCount = 5
    @State private var promptCountMode: PromptCountMode = .automatic
    @State private var showAdditionalPromptsStack = false
    @State private var showAIAccount = false
    @State private var showPodcastBacklog = false
    @State private var showPodcastSearch = false
    @State private var browsedEpisode: BrowsedEpisodeSelection?
    @State private var importTask: Task<Void, Never>?
    @State private var loadedSourceText = ""
    @State private var isLoadingSavedEpisode = false
    @State private var episodeDetailsExpanded = false
    @State private var addPromptExpanded = false
    @State private var showPromptResetConfirmation = false
    @State private var promptResetEpisodeID: UUID?
    @State private var promptResetStatusText = ""

    var body: some View {
        let visiblePrompts = Array(episodeStore.episode.prompts.prefix(3))
        let additionalPrompts = Array(episodeStore.episode.prompts.dropFirst(3))

        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit Episode & Prompts")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)

                    Text("Work through the steps below. Changes to prompts save automatically.")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }
                Spacer()
                AgoraTag(text: appVersionLabel)
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(AgoraOutlineButtonStyle())
                .disabled(isResolving || isPreparingTranscript)
            }

            AgoraCard {
                HStack(spacing: 12) {
                    Image(systemName: hasUsableAI ? "checkmark.shield.fill" : "person.badge.key.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(AgoraTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(aiAccessTitle)
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.ink)
                        Text(aiAccessDetail)
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }
                    Spacer()
                    Button(hasUsableAI ? "Manage" : "Set Up") {
                        showAIAccount = true
                    }
                    .buttonStyle(AgoraOutlineButtonStyle())
                }
            }

            AgoraCard {
                VStack(alignment: .leading, spacing: 12) {
                    editorStepHeader(
                        number: 1,
                        title: "Choose an Episode",
                        detail: "Paste a link or browse for a podcast."
                    )

                    Text("Podcast Link")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                    TextField("https://...", text: $audioURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isResolving || isPreparingTranscript)
                        .agoraFieldStyle()
                        .overlay(alignment: .trailing) {
                            if !audioURLText.isEmpty {
                                Button {
                                    audioURLText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(AgoraTheme.inkMuted)
                                        .padding(.trailing, 10)
                                }
                                .accessibilityLabel("Clear URL")
                                .disabled(isResolving || isPreparingTranscript)
                            }
                        }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            browsePodcastsButton
                            podcastBacklogButton
                        }
                        VStack(spacing: 10) {
                            browsePodcastsButton
                            podcastBacklogButton
                        }
                    }

                    if hasPendingSourceChange {
                        Label("New podcast link ready to import", systemImage: "arrow.triangle.2.circlepath")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.accent)
                    }

                    Text("Paste an episode or show link from Spotify, Apple Podcasts, Pocket Casts, Overcast, Amazon Music, iHeart, YouTube Music, a public RSS feed, or a direct audio link.")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }
            }

            AgoraCard {
                VStack(alignment: .leading, spacing: 12) {
                    editorStepHeader(
                        number: 2,
                        title: "Analyze & Save",
                        detail: "Let AI choose the right number of questions, or set it yourself."
                    )

                    Picker("Prompt Count", selection: $promptCountMode) {
                        ForEach(PromptCountMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isResolving || isPreparingTranscript)

                    if promptCountMode == .manual {
                        HStack {
                            Text("Number of prompts")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                            Spacer()
                            Menu {
                                ForEach(3...12, id: \.self) { count in
                                    Button("\(count) prompts") {
                                        selectedPromptCount = count
                                    }
                                }
                            } label: {
                                Text("\(selectedPromptCount) prompts")
                            }
                            .buttonStyle(AgoraOutlineButtonStyle())
                            .disabled(isResolving || isPreparingTranscript)
                        }
                    } else {
                        Text("Automatic adapts to episode length, content depth, and the number of important ideas.")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }

                    Button("Import, Analyze & Save") {
                        if hasUsableAI {
                            importTask = Task { await importAndSaveEpisode() }
                        } else {
                            showAIAccount = true
                        }
                    }
                    .buttonStyle(AgoraPillButtonStyle())
                    .disabled(isResolving || isPreparingTranscript)

                    if isResolving {
                        ProgressView(importStatusText.isEmpty ? "Finding this episode..." : importStatusText)
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    } else if isPreparingTranscript {
                        ProgressView(importStatusText.isEmpty ? "Preparing transcript and summary..." : importStatusText)
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    } else if !importStatusText.isEmpty {
                        Text(importStatusText)
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }

                    if isResolving || isPreparingTranscript {
                        HStack {
                            Text("Episode details are saved as soon as they are found. Longer audio may take several minutes to transcribe.")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                            Spacer()
                            Button("Cancel") {
                                importTask?.cancel()
                            }
                            .buttonStyle(AgoraOutlineButtonStyle())
                        }
                    }
                }
            }

            AgoraCard {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            episodeDetailsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            editorStepHeader(
                                number: 3,
                                title: "Review Episode Details",
                                detail: episodeDetailsSummary
                            )
                            Spacer()
                            Image(systemName: episodeDetailsExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(AgoraTheme.accent)
                        }
                    }
                    .buttonStyle(.plain)

                    if episodeDetailsExpanded {
                        Divider()

                        Text("Episode Title")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                        TextField("Fills in after import", text: $titleText)
                            .agoraFieldStyle()

                        Text("Episode Summary")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                        AgoraExpandableText(
                            text: summaryText.isEmpty ? "A useful episode summary will appear after import." : summaryText,
                            collapsedLineLimit: 4,
                            expansionThreshold: 260,
                            color: summaryText.isEmpty ? AgoraTheme.inkMuted : AgoraTheme.ink
                        )
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.85))
                            .cornerRadius(14)

                        Text("Episode Transcript")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                        transcriptEditor
                    }
                }
            }

            editorStepHeader(
                number: 4,
                title: "Review Prompts",
                detail: episodeStore.episode.prompts.isEmpty
                    ? "Generated questions will appear here."
                    : "\(episodeStore.episode.prompts.count) questions saved automatically."
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if !episodeStore.episode.prompts.isEmpty {
                AgoraCard {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 12) {
                            Text("Complete prompt timeline")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                            Spacer(minLength: 8)
                            Button {
                                promptResetEpisodeID = episodeStore.episode.id
                                showPromptResetConfirmation = true
                            } label: {
                                Label("Reset", systemImage: "arrow.counterclockwise")
                            }
                            .buttonStyle(AgoraPillButtonStyle())
                            .disabled(isResolving || isPreparingTranscript)
                            .accessibilityLabel("Reset this episode's prompt progress")
                            .accessibilityHint("Clears answers and grades and rewinds this episode, keeping its questions and earned points")
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(episodeStore.episode.prompts.sorted { $0.timestampSeconds < $1.timestampSeconds }) { prompt in
                                    AgoraTag(text: formatEpisodeTime(prompt.timestampSeconds))
                                }
                            }
                        }
                        Text("\(episodeStore.episode.prompts.count) questions across \(formatEpisodeTime(promptEditorDurationSeconds)). Later prompts remain visible here even when their editor cards are collapsed below.")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                        if !promptResetStatusText.isEmpty {
                            Text(promptResetStatusText)
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.accent)
                                .accessibilityIdentifier("promptResetStatus")
                        }
                    }
                }
            }

            ForEach(Array(visiblePrompts.enumerated()), id: \.element.id) { index, prompt in
                PromptRow(index: index, prompt: prompt, episodeDuration: promptEditorDurationSeconds) {
                    episodeStore.deletePrompt(prompt)
                } onUpdate: { updated in
                    episodeStore.updatePrompt(updated)
                }
            }

            if !additionalPrompts.isEmpty {
                Button(showAdditionalPromptsStack ? "Hide additional prompts" : "See additional prompts generated") {
                    showAdditionalPromptsStack.toggle()
                }
                .buttonStyle(AgoraOutlineButtonStyle())
            }

            if showAdditionalPromptsStack, !additionalPrompts.isEmpty {
                AdditionalPromptsCarousel(
                    prompts: additionalPrompts,
                    startIndex: visiblePrompts.count,
                    episodeDuration: promptEditorDurationSeconds
                ) { prompt in
                    episodeStore.deletePrompt(prompt)
                } onUpdate: { updated in
                    episodeStore.updatePrompt(updated)
                }
                .frame(height: 640)
            }

            AgoraCard {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            addPromptExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(AgoraTheme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Add a Prompt Manually")
                                    .font(AgoraTheme.cardTitleFont)
                                    .foregroundColor(AgoraTheme.ink)
                                Text("Optional: create your own question and answer.")
                                    .font(AgoraTheme.tagFont)
                                    .foregroundColor(AgoraTheme.inkMuted)
                            }
                            Spacer()
                            Image(systemName: addPromptExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(AgoraTheme.accent)
                        }
                    }
                    .buttonStyle(.plain)

                    if addPromptExpanded {
                        Divider()

                        TextField("Answer heard by (seconds)", text: $newTimestamp)
                            .keyboardType(.decimalPad)
                            .agoraFieldStyle()

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Extra Delay: \(Int(newLeadTime))s after answer")
                                    .font(AgoraTheme.tagFont)
                                    .foregroundColor(AgoraTheme.inkMuted)
                                Spacer()
                                Menu {
                                    ForEach([0, 5, 10, 15, 20, 30], id: \.self) { step in
                                        Button("\(step)s") { newLeadTime = Double(step) }
                                    }
                                } label: {
                                    Text("Quick Select")
                                }
                                .buttonStyle(AgoraOutlineButtonStyle())
                            }
                            Slider(value: $newLeadTime, in: 0...60, step: 5)
                        }
                        .padding(.top, 4)

                        TextField("Question", text: $newQuestion)
                            .agoraFieldStyle()

                        TextField("Expected answer", text: $newAnswer)
                            .agoraFieldStyle()

                        Button("Add Prompt") {
                            addPrompt()
                        }
                        .buttonStyle(AgoraPillButtonStyle())
                        .disabled(promptValidationMessage != nil)

                        if let promptValidationMessage {
                            Text(promptValidationMessage)
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                        }
                    }
                }
            }
        }
        .padding(16)
        .onAppear {
            loadSavedEpisodeFields()
            resumeCloudAnalysisIfNeeded()
        }
        .onChange(of: episodeStore.episode.id) { _ in
            showPromptResetConfirmation = false
            promptResetEpisodeID = nil
            promptResetStatusText = ""
            loadSavedEpisodeFields()
        }
        .onChange(of: audioURLText) { newValue in
            guard !isLoadingSavedEpisode, normalizedSourceText(newValue) != loadedSourceText else { return }
            titleText = ""
            transcriptText = ""
            summaryText = ""
            transcriptExpanded = false
            showAdditionalPromptsStack = false
            importStatusText = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ""
                : "New link detected. Import will replace the current episode."
        }
        .alert("Reset Prompt Progress?", isPresented: $showPromptResetConfirmation) {
            Button("Reset & Rewind", role: .destructive) {
                guard let episodeID = promptResetEpisodeID,
                      episodeStore.episode.id == episodeID else { return }
                if onResetPromptProgress(episodeID) {
                    promptResetStatusText = "Ready to replay. Tap Done, then Play to hear these questions again."
                }
                promptResetEpisodeID = nil
            }
            Button("Cancel", role: .cancel) { promptResetEpisodeID = nil }
        } message: {
            Text("This clears this episode's saved answers and grades and rewinds it to the beginning. Your prompts, transcript, and earned Agora Points are kept. Repeating an answer won't award the same points again.")
        }
        .alert("Invalid URL", isPresented: $showInvalidURL) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Paste one complete podcast page, public RSS feed, or direct audio link.")
        }
        .alert("Podcast Analysis", isPresented: $showAnalysisError) {
            if showProviderCreditsAction {
                Button("Open Provider Credits") {
                    openURL(AppLinks.providerCredits)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(analysisErrorMessage)
        }
        .sheet(isPresented: $showAIAccount) {
            AIAccountView()
                .environmentObject(aiAccount)
        }
        .sheet(isPresented: $showPodcastBacklog) {
            PodcastBacklogView(episodeStore: episodeStore)
                .environmentObject(aiAccount)
        }
        .sheet(isPresented: $showPodcastSearch) {
            PodcastSearchView { picks in
                guard let pick = picks.first else { return }
                applyBrowsedEpisode(feedURL: pick.feedURL, guid: pick.guid, title: pick.title)
            }
        }
    }

    private func editorStepHeader(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Text("\(number)")
                .font(AgoraTheme.buttonFont)
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(AgoraTheme.accent))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AgoraTheme.cardTitleFont)
                    .foregroundColor(AgoraTheme.ink)
                Text(detail)
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)
                    .lineLimit(2)
            }
        }
    }

    private var browsePodcastsButton: some View {
        Button {
            showPodcastSearch = true
        } label: {
            Label("Browse Podcasts", systemImage: "magnifyingglass")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AgoraOutlineButtonStyle())
        .disabled(isResolving || isPreparingTranscript)
        .accessibilityHint("Search podcasts and pick an episode without leaving Agora")
    }

    private var podcastBacklogButton: some View {
        Button {
            showPodcastBacklog = true
        } label: {
            Label("Podcast Backlog", systemImage: "rectangle.stack.badge.plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(AgoraOutlineButtonStyle())
        .disabled(isResolving || isPreparingTranscript)
        .accessibilityHint("Opens the multi-episode podcast analysis queue")
    }

    @ViewBuilder
    private var transcriptEditor: some View {
        if transcriptExpanded {
            TextEditor(text: $transcriptText)
                .scrollContentBackground(.hidden)
                .foregroundColor(AgoraTheme.ink)
                .background(Color.clear)
                .frame(minHeight: 200)
                .padding(10)
                .background(Color.white.opacity(0.85))
                .cornerRadius(14)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                )
            HStack {
                Spacer()
                Button("Show less") { transcriptExpanded = false }
                    .buttonStyle(AgoraOutlineButtonStyle())
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No transcript yet")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                } else {
                    Text(transcriptText)
                        .font(AgoraTheme.bodyFont)
                        .foregroundColor(AgoraTheme.ink)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Spacer()
                    Button("Show more") { transcriptExpanded = true }
                        .buttonStyle(AgoraOutlineButtonStyle())
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.85))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AgoraTheme.cardStroke, lineWidth: 1)
            )
        }
    }

    private var episodeDetailsSummary: String {
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return "Title, summary, and full transcript." }
        return title
    }

    private var hasUsableAI: Bool {
        aiAccount.isConnected
    }

    private var aiAccessTitle: String {
        aiAccount.isConnected ? "Your AI is connected" : "Connect your AI"
    }

    private var aiAccessDetail: String {
        aiAccount.isConnected
            ? "Analysis is billed directly to the provider account you connected."
            : "The Agora is free. Connect a provider account to run transcript analysis."
    }

    @MainActor
    private func loadSavedEpisodeFields() {
        isLoadingSavedEpisode = true
        audioURLText = episodeStore.episode.audioURL.isFileURL
            ? ""
            : (episodeStore.episode.sourceURL ?? episodeStore.episode.audioURL).absoluteString
        loadedSourceText = normalizedSourceText(audioURLText)
        titleText = episodeStore.episode.audioURL.isFileURL ? "" : episodeStore.episode.title
        transcriptText = episodeStore.episode.transcript ?? ""
        summaryText = episodeStore.episode.summary ?? ""
        transcriptExpanded = false
        showAdditionalPromptsStack = false
        isLoadingSavedEpisode = false
    }

    /// A browsed episode fills the URL field with its show's feed and remembers
    /// which episode was picked, then runs the same import the paste path runs.
    @MainActor
    private func applyBrowsedEpisode(feedURL: URL, guid: String?, title: String) {
        let sourceText = normalizedSourceText(feedURL.absoluteString)
        audioURLText = feedURL.absoluteString
        browsedEpisode = BrowsedEpisodeSelection(
            sourceText: sourceText,
            feedURL: feedURL,
            guid: guid,
            title: title
        )
        guard hasUsableAI else {
            showAIAccount = true
            return
        }
        guard !isResolving, !isPreparingTranscript else { return }
        importTask = Task { await importAndSaveEpisode() }
    }

    @MainActor
    private func importAndSaveEpisode() async {
        guard !isResolving, !isPreparingTranscript else { return }
        isResolving = true
        importStatusText = "Finding the episode and its feed..."
        defer {
            isResolving = false
            importTask = nil
        }

        do {
            let inputURL = try validatedInputURL()
            let requestedSourceText = normalizedSourceText(inputURL.absoluteString)
            let service = PodcastImportService()
            let imported: PodcastImportResult
            if let selection = browsedEpisode, selection.sourceText == requestedSourceText {
                imported = try await service.importEpisode(
                    feedURL: selection.feedURL,
                    guid: selection.guid,
                    title: selection.title
                )
            } else {
                imported = try await service.importMetadata(from: inputURL)
            }
            try Task.checkCancellation()
            guard normalizedSourceText(audioURLText) == requestedSourceText else {
                importStatusText = "The podcast link changed before import finished. Tap Import, Analyze & Save again to use the new link."
                return
            }
            let oldTranscript = (episodeStore.episode.transcript ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let editedTranscript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceChanged = !episodeStore.matchesResolvedEpisode(
                audioURL: imported.audioURL,
                feedURL: imported.feedURL,
                episodeGUID: imported.episodeGUID
            )
            let preferredTranscript = sourceChanged && editedTranscript == oldTranscript
                ? nil
                : (editedTranscript.isEmpty ? nil : editedTranscript)
            let transcriptChanged = !sourceChanged && editedTranscript != oldTranscript
            let promptCountMatches = promptCountMode == .automatic
                || episodeStore.episode.prompts.count == selectedPromptCount
            let editedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            let preferredTitle = imported.feedURL == nil && !editedTitle.isEmpty
                ? editedTitle
                : (!sourceChanged && !editedTitle.isEmpty && editedTitle != episodeStore.episode.title
                    ? editedTitle
                    : nil)

            applyImportedMetadata(
                imported,
                sourceURL: inputURL,
                preferredTitle: preferredTitle,
                preferredTranscript: preferredTranscript
            )
            isResolving = false
            guard hasUsableAI else {
                importStatusText = "Episode details saved. Connect your AI when you are ready to create a transcript and prompts."
                return
            }
            let alreadyPrepared = !sourceChanged
                && !transcriptChanged
                && promptCountMatches
                && (preferredTranscript?.split(whereSeparator: { $0.isWhitespace }).count ?? 0) >= 120
                && episodeStore.episode.prompts.count >= requiredPromptCount(
                    duration: imported.durationSeconds ?? estimateDurationFromTranscript(preferredTranscript ?? "")
                )
                && PodcastPromptPolicy.hasAdequateCoverage(
                    episodeStore.episode.prompts,
                    duration: imported.durationSeconds ?? estimateDurationFromTranscript(preferredTranscript ?? "")
                )
                && !(episodeStore.episode.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if alreadyPrepared {
                importStatusText = "Episode loaded instantly. Its saved transcript, brief, and prompts are ready."
                return
            }
            importStatusText = "Episode saved. Analyzing the complete podcast..."
            isPreparingTranscript = true
            if CloudAnalysisClient.isConfigured {
                await prepareCloudEpisode(
                    imported,
                    preferredTranscript: preferredTranscript,
                    forceRefresh: !sourceChanged
                )
            } else {
                await prepareCompleteEpisode(imported, preferredTranscript: preferredTranscript)
            }
        } catch {
            if operationWasCancelled(error) {
                importStatusText = "Analysis canceled. The episode details already saved were kept."
            } else {
                importStatusText = ""
                presentAnalysisError(error)
            }
        }
    }

    @MainActor
    private func prepareCloudEpisode(
        _ imported: PodcastImportResult,
        preferredTranscript: String?,
        forceRefresh: Bool
    ) async {
        defer { isPreparingTranscript = false }
        do {
            guard let providerKey = AIAccountStore.apiKey() else { throw OpenRouterClientError.notConnected }
            let duration = imported.durationSeconds ?? estimateDurationFromTranscript(preferredTranscript ?? "")
            let count: Int? = promptCountMode == .manual ? selectedPromptCount : nil
            let (analysis, expectedURL, completedJobID) = try await CloudAnalysisClient().submitAndWait(
                title: titleText,
                audioURL: imported.audioURL,
                transcript: preferredTranscript,
                transcriptSource: imported.transcriptSource,
                duration: duration > 10 ? duration : nil,
                promptCount: count,
                model: AIAccountStore.selectedModelID(),
                providerAPIKey: providerKey,
                forceRefresh: forceRefresh,
                progress: { status in
                    Task { @MainActor in self.importStatusText = status }
                }
            )
            try await applyAnalysis(analysis, expectedAudioURL: expectedURL)
            CloudAnalysisClient.acknowledgeSavedAnalysis(jobID: completedJobID)
            selectedPromptCount = analysis.recommendedPromptCount
            importStatusText = "Episode brief, full transcript, and \(analysis.prompts.count) prompts are ready."
        } catch {
            if !operationWasCancelled(error), shouldFallBackToDirectAnalysis(error) {
                importStatusText = "Cloud analysis is unavailable. Continuing through your connected AI; keep Agora open for this run."
                await prepareCompleteEpisode(imported, preferredTranscript: preferredTranscript)
                return
            }
            importStatusText = "Episode details were saved, but cloud analysis could not finish."
            presentAnalysisError(error)
        }
    }

    private func shouldFallBackToDirectAnalysis(_ error: Error) -> Bool {
        if error is URLError || error is CloudAnalysisError { return true }
        return false
    }

    @MainActor
    private func resumeCloudAnalysisIfNeeded() {
        guard CloudAnalysisClient.isConfigured,
              CloudAnalysisClient.pendingAnalysis != nil,
              importTask == nil else { return }
        isPreparingTranscript = true
        importTask = Task {
            defer {
                isPreparingTranscript = false
                importTask = nil
            }
            do {
                guard let (analysis, expectedURL, completedJobID) = try await CloudAnalysisClient().resumePending(progress: { status in
                    Task { @MainActor in self.importStatusText = status }
                }) else { return }
                try await applyAnalysis(analysis, expectedAudioURL: expectedURL)
                CloudAnalysisClient.acknowledgeSavedAnalysis(jobID: completedJobID)
                selectedPromptCount = analysis.recommendedPromptCount
                importStatusText = "Your cloud analysis is complete and ready."
            } catch {
                presentAnalysisError(error)
            }
        }
    }

    @MainActor
    private func applyImportedMetadata(
        _ imported: PodcastImportResult,
        sourceURL: URL,
        preferredTitle: String?,
        preferredTranscript: String?
    ) {
        let importedTitle = preferredTitle ?? imported.title
        let initialSummary = imported.publisherSummary
            ?? (imported.audioURL == episodeStore.episode.audioURL ? episodeStore.episode.summary : nil)

        titleText = importedTitle
        isLoadingSavedEpisode = true
        audioURLText = sourceURL.absoluteString
        loadedSourceText = normalizedSourceText(sourceURL.absoluteString)
        isLoadingSavedEpisode = false
        transcriptText = preferredTranscript ?? ""
        summaryText = initialSummary ?? ""
        if let duration = imported.durationSeconds { PlayerDurationCache.shared.duration = duration }
        episodeStore.importEpisode(
            title: importedTitle,
            audioURL: imported.audioURL,
            sourceURL: sourceURL,
            feedURL: imported.feedURL,
            episodeGUID: imported.episodeGUID,
            transcript: preferredTranscript,
            summary: initialSummary,
            durationSeconds: imported.durationSeconds,
            artworkURL: imported.artworkURL
        )
    }

    @MainActor
    private func prepareCompleteEpisode(
        _ imported: PodcastImportResult,
        preferredTranscript: String?
    ) async {
        defer { isPreparingTranscript = false }
        do {
            var transcript = preferredTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !PodcastPromptPolicy.transcriptAppearsComplete(
                transcript,
                duration: imported.durationSeconds
            ),
               let source = imported.transcriptSource {
                importStatusText = "Downloading the published transcript..."
                transcript = (try? await PodcastImportService().downloadTranscript(from: source)) ?? ""
            }

            try Task.checkCancellation()
            var transcriptionDuration: Double?
            if !PodcastPromptPolicy.transcriptAppearsComplete(
                transcript,
                duration: imported.durationSeconds
            ) {
                let transcription = try await AIService().transcribeAudio(at: imported.audioURL) { status in
                    Task { @MainActor in
                        guard isPreparingTranscript else { return }
                        importStatusText = status
                    }
                }
                transcript = transcription.transcript
                transcriptionDuration = transcription.duration
            }

            guard transcript.split(whereSeparator: { $0.isWhitespace }).count >= 120 else {
                throw AIServiceError.transcriptTooShort
            }
            transcriptText = transcript
            if episodeStore.episode.audioURL == imported.audioURL {
                episodeStore.updateTranscript(transcript)
            }
            importStatusText = "Transcript saved. Building the episode brief and best questions..."

            let estimatedDuration = estimateDurationFromTranscript(transcript)
            let effectiveDuration = [transcriptionDuration, imported.durationSeconds, estimatedDuration]
                .compactMap { $0 }
                .first { $0.isFinite && $0 > 10 }
            let analysis = try await AIService().analyzeEpisode(
                title: titleText,
                audioURL: nil,
                transcript: transcript,
                audioDuration: effectiveDuration,
                desiredCount: promptCountMode == .manual ? selectedPromptCount : nil,
                progress: { status in
                    Task { @MainActor in
                        guard isPreparingTranscript else { return }
                        importStatusText = status
                    }
                }
            )
            try await applyAnalysis(analysis, expectedAudioURL: imported.audioURL)
            if promptCountMode == .automatic {
                selectedPromptCount = analysis.recommendedPromptCount
            }
            importStatusText = "Episode brief, full transcript, and \(analysis.prompts.count) prompts are ready."
        } catch {
            if operationWasCancelled(error) {
                importStatusText = "Analysis canceled. Saved episode details and transcript were kept."
            } else {
                importStatusText = "Episode details were saved, but analysis could not finish."
                presentAnalysisError(error)
            }
        }
    }

    @MainActor
    private func presentAnalysisError(_ error: Error) {
        if error is PromptEditorError {
            showInvalidURL = true
            return
        }
        analysisErrorMessage = error.localizedDescription
        if case OpenRouterClientError.insufficientCredits = error {
            showProviderCreditsAction = true
        } else {
            showProviderCreditsAction = false
        }
        showAnalysisError = true
    }

    @MainActor
    private func applyAnalysis(_ analysis: EpisodeAnalysisResult, expectedAudioURL: URL) async throws {
        let requiredCount = requiredPromptCount(duration: analysis.duration)
        guard analysis.prompts.count >= requiredCount,
              PodcastPromptPolicy.hasAdequateCoverage(analysis.prompts, duration: analysis.duration) else {
            throw AIServiceError.noQualityPrompts
        }
        try await episodeStore.saveAnalysis(analysis, expectedAudioURL: expectedAudioURL)
        transcriptText = analysis.transcript
        summaryText = analysis.summary
        if analysis.duration.isFinite, analysis.duration > 10 {
            PlayerDurationCache.shared.duration = analysis.duration
        }
    }

    private func validatedInputURL() throws -> URL {
        guard let url = PodcastSourceParser.urls(in: audioURLText).first else {
            throw PromptEditorError.invalidURL
        }
        return url
    }

    private var hasPendingSourceChange: Bool {
        !audioURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && normalizedSourceText(audioURLText) != loadedSourceText
    }

    private func normalizedSourceText(_ value: String) -> String {
        PodcastSourceParser.urls(in: value).first?.absoluteString
            ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func operationWasCancelled(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return Task.isCancelled
    }

    private func estimateDurationFromTranscript(_ transcript: String) -> Double {
        let words = transcript.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        if words == 0 { return 0 }
        // 2.6 words/sec ~= 156 wpm typical spoken pace.
        let estimated = Double(words) / 2.6
        return max(180, min(86_400, estimated))
    }

    private func requiredPromptCount(duration: Double) -> Int {
        if promptCountMode == .manual { return selectedPromptCount }
        return PodcastPromptPolicy.minimumCount(for: duration)
    }

    private func addPrompt() {
        guard let timestamp = Double(newTimestamp), timestamp.isFinite,
              timestamp >= 1, timestamp <= promptEditorDurationSeconds else { return }
        let question = newQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = newAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !answer.isEmpty else { return }

        let prompt = Prompt(
            id: UUID(),
            timestampSeconds: timestamp,
            question: question,
            expectedAnswer: answer,
            leadTimeSeconds: newLeadTime
        )

        episodeStore.addPrompt(prompt)
        newTimestamp = ""
        newQuestion = ""
        newAnswer = ""
        newLeadTime = 0
    }

    private var promptValidationMessage: String? {
        let hasAnyInput = !newTimestamp.isEmpty || !newQuestion.isEmpty || !newAnswer.isEmpty
        guard hasAnyInput else { return "Enter when the answer has been heard, the question, and its podcast-supported answer." }
        guard let timestamp = Double(newTimestamp), timestamp.isFinite else {
            return "Enter the timestamp in seconds."
        }
        guard timestamp >= 1, timestamp <= promptEditorDurationSeconds else {
            return "Choose a timestamp between 1 second and \(Int(promptEditorDurationSeconds)) seconds."
        }
        guard !newQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter the question to ask the listener."
        }
        guard !newAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter the answer supported by the podcast."
        }
        return nil
    }

    private var promptEditorDurationSeconds: Double {
        let maxPrompt = episodeStore.episode.prompts.map(\.timestampSeconds).max() ?? 0
        return max(episodeStore.episode.durationSeconds ?? 0, PlayerDurationCache.shared.duration, maxPrompt + 60, 600)
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(version) (\(build))"
    }

    private func formatEpisodeTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = max(Int(seconds.rounded()), 0)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct PromptRow: View {
    let index: Int
    let prompt: Prompt
    let episodeDuration: Double
    let onDelete: () -> Void
    let onUpdate: (Prompt) -> Void

    @State private var question: String
    @State private var expectedAnswer: String
    @State private var timestampSeconds: Double
    @State private var leadTimeSeconds: Double
    @State private var showFullQuestion = false
    @State private var showFullAnswer = false
    @State private var isExpanded = false

    init(index: Int, prompt: Prompt, episodeDuration: Double, onDelete: @escaping () -> Void, onUpdate: @escaping (Prompt) -> Void) {
        self.index = index
        self.prompt = prompt
        self.episodeDuration = episodeDuration
        self.onDelete = onDelete
        self.onUpdate = onUpdate
        _question = State(initialValue: prompt.question)
        _expectedAnswer = State(initialValue: prompt.expectedAnswer)
        _timestampSeconds = State(initialValue: min(max(prompt.timestampSeconds, 1), max(episodeDuration, 60)))
        _leadTimeSeconds = State(initialValue: prompt.leadTimeSeconds)
    }

    var body: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("Prompt \(index + 1)")
                                    .font(AgoraTheme.cardTitleFont)
                                    .foregroundColor(AgoraTheme.ink)
                                AgoraTag(text: positionLabel)
                            }
                            Text(question.isEmpty ? "Untitled question" : question)
                                .font(AgoraTheme.bodyFont)
                                .foregroundColor(AgoraTheme.ink)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text("Ask after \(formatSeconds(timestampSeconds))")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                        }
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(AgoraTheme.accent)
                            .padding(.top, 5)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider()

                    HStack {
                        Text("Prompt \(index + 1) settings")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                        Spacer()
                        Button("Delete") {
                            onDelete()
                        }
                        .buttonStyle(AgoraOutlineButtonStyle())
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Answer heard by")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                            Spacer()
                            Menu {
                                ForEach(quickSelectTimestamps, id: \.self) { value in
                                    Button("\(formatSeconds(value))") { timestampSeconds = value }
                                }
                            } label: {
                                Text("Quick Select")
                            }
                            .buttonStyle(AgoraOutlineButtonStyle())
                        }
                        Slider(value: $timestampSeconds, in: timestampRange, step: timestampStep)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Extra Delay: \(Int(leadTimeSeconds))s after answer")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                            Spacer()
                            Menu {
                                ForEach([0, 5, 10, 15, 20, 30], id: \.self) { step in
                                    Button("\(step)s") { leadTimeSeconds = Double(step) }
                                }
                            } label: {
                                Text("Quick Select")
                            }
                            .buttonStyle(AgoraOutlineButtonStyle())
                        }
                        Slider(value: $leadTimeSeconds, in: 0...60, step: 5)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Question")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)

                        if showFullQuestion {
                            TextEditor(text: $question)
                                .scrollContentBackground(.hidden)
                                .foregroundColor(AgoraTheme.ink)
                                .background(Color.clear)
                                .frame(height: 130)
                                .agoraFieldStyle()
                        } else {
                            TextField("Question", text: $question)
                                .agoraFieldStyle()
                        }

                        HStack {
                            Spacer()
                            Button(showFullQuestion ? "Show less" : "Show more") {
                                showFullQuestion.toggle()
                            }
                            .buttonStyle(AgoraOutlineButtonStyle())
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Expected Answer")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)

                        if showFullAnswer {
                            TextEditor(text: $expectedAnswer)
                                .scrollContentBackground(.hidden)
                                .foregroundColor(AgoraTheme.ink)
                                .background(Color.clear)
                                .frame(height: 130)
                                .agoraFieldStyle()
                        } else {
                            TextField("Expected answer", text: $expectedAnswer)
                                .agoraFieldStyle()
                        }

                        HStack {
                            Spacer()
                            Button(showFullAnswer ? "Show less" : "Show more") {
                                showFullAnswer.toggle()
                            }
                            .buttonStyle(AgoraOutlineButtonStyle())
                        }
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(AgoraTheme.accent)
                        Text("Changes save automatically")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }
                }
            }
        }
        .onChange(of: question) { _ in persistChanges() }
        .onChange(of: expectedAnswer) { _ in persistChanges() }
        .onChange(of: timestampSeconds) { _ in persistChanges() }
        .onChange(of: leadTimeSeconds) { _ in persistChanges() }
    }

    private func persistChanges() {
        let updated = Prompt(
            id: prompt.id,
            timestampSeconds: min(max(timestampSeconds, 1), max(episodeDuration, 60)),
            question: question.trimmingCharacters(in: .whitespacesAndNewlines),
            expectedAnswer: expectedAnswer.trimmingCharacters(in: .whitespacesAndNewlines),
            leadTimeSeconds: leadTimeSeconds
        )
        onUpdate(updated)
    }

    private var positionLabel: String {
        let progress = timestampSeconds / max(episodeDuration, 1)
        switch progress {
        case ..<0.34: return "Beginning"
        case ..<0.67: return "Middle"
        default: return "Late"
        }
    }

    private var timestampRange: ClosedRange<Double> {
        1...max(episodeDuration, 60)
    }

    private var timestampStep: Double {
        let duration = max(episodeDuration, 1)
        if duration >= 10_800 { return 60 } // 3h+
        if duration >= 3_600 { return 30 }  // 1h+
        if duration >= 1_200 { return 15 }  // 20m+
        return 5
    }

    private var quickSelectTimestamps: [Double] {
        let r = timestampRange
        let span = r.upperBound - r.lowerBound
        guard span > 1 else { return [r.lowerBound] }
        let step = span / 4
        return (0...4).map { i in
            r.lowerBound + (Double(i) * step)
        }
    }

    private func formatSeconds(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600
        let minutes = (s % 3600) / 60
        let r = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, minutes, r) }
        let shortMinutes = s / 60
        if shortMinutes > 0 { return String(format: "%d:%02d", shortMinutes, r) }
        return "\(s)s"
    }
}

private struct AdditionalPromptsCarousel: View {
    let prompts: [Prompt]
    let startIndex: Int
    let episodeDuration: Double
    let onDelete: (Prompt) -> Void
    let onUpdate: (Prompt) -> Void

    @State private var selection = 0

    var body: some View {
        AgoraCard {
            VStack(spacing: 12) {
                if prompts.isEmpty {
                    Text("No additional prompts available.")
                        .font(AgoraTheme.bodyFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    TabView(selection: $selection) {
                        ForEach(Array(prompts.enumerated()), id: \.element.id) { offset, prompt in
                            PromptRow(
                                index: startIndex + offset,
                                prompt: prompt,
                                episodeDuration: episodeDuration
                            ) {
                                onDelete(prompt)
                            } onUpdate: { updated in
                                onUpdate(updated)
                            }
                            .tag(offset)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 12)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    .indexViewStyle(.page(backgroundDisplayMode: .always))
                }
            }
            .padding(10)
        }
    }
}

private actor PlayerDurationProvider {
    static let shared = PlayerDurationProvider()
    private init() {}

    var currentDuration: Double {
        // Attempt to read duration via NotificationCenter or a shared reference if available.
        // As a simple approximation, return a reasonable default if unknown.
        // This can be replaced by a proper dependency injection of the player if desired.
        return  max(PlayerDurationCache.shared.duration, 1)
    }
}
