import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()
    @EnvironmentObject private var pointsStore: PointsStore
    @EnvironmentObject private var episodeStore: EpisodeStore
    @EnvironmentObject private var aiAccount: AIAccountStore
    @State private var showEditor = false
    @State private var showAIAccount = false
    @State private var showPlaybackSettings = false

    var body: some View {
        NavigationView {
            ZStack {
                AgoraBackgroundView()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        header
                        episodeEditorButton

                        if !hasUsableAI {
                            aiSetupCard
                        }

                        if hasConfiguredEpisode {
                            if !episodeStore.episode.audioURL.isFileURL {
                                PlayerView(viewModel: viewModel)
                            }

                            donationCard
                        } else {
                            emptyEpisodeCard
                            donationCard
                        }

                        pointsCard
                        legalLinks
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarHidden(true)
            .alert("Changes Need Saving", isPresented: Binding(
                get: { episodeStore.saveError != nil },
                set: { if !$0 { episodeStore.saveError = nil } }
            )) {
                Button("Retry Save") { episodeStore.retrySaving() }
                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text(episodeStore.saveError ?? "Please retry saving your changes.")
            }
            .sheet(isPresented: $showEditor) {
                ScrollView {
                    PromptEditorView(episodeStore: episodeStore) { episodeID in
                        guard episodeStore.episode.id == episodeID else { return false }
                        viewModel.updateEpisode(episodeStore.episode)
                        return viewModel.resetPromptProgress(for: episodeID)
                    }
                        .padding(.vertical, 24)
                }
                .background(AgoraBackgroundView())
                .onDisappear {
                    viewModel.updateEpisode(episodeStore.episode)
                }
            }
            .sheet(isPresented: $showAIAccount) {
                AIAccountView()
                    .environmentObject(aiAccount)
            }
            .sheet(isPresented: $showPlaybackSettings) {
                PlaybackSettingsView(viewModel: viewModel)
            }
            .onAppear {
                viewModel.updateEpisode(episodeStore.episode)
            }
            .onReceive(NotificationCenter.default.publisher(for: .audioDurationUpdated)) { notification in
                if let duration = notification.userInfo?["duration"] as? Double {
                    PlayerDurationCache.shared.duration = duration
                    episodeStore.updateDuration(duration)
                }
            }
            .onReceive(episodeStore.$episode) { updated in
                viewModel.updateEpisode(updated)
            }
            .onReceive(NotificationCenter.default.publisher(for: .aiConnectionInvalidated)) { _ in
                aiAccount.invalidateConnection()
            }
            .task {
                await aiAccount.refreshConnectionStatus()
            }
        }
    }

    private var hasConfiguredEpisode: Bool {
        !episodeStore.episode.audioURL.isFileURL
    }

    private var hasUsableAI: Bool {
        aiAccount.isConnected
    }

    private var episodeEditorButton: some View {
        Button {
            showEditor = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: hasConfiguredEpisode ? "slider.horizontal.3" : "plus.circle.fill")
                    .font(.system(size: 21, weight: .semibold))

                Text(hasConfiguredEpisode ? "Edit Episode & Prompts" : "Import a Podcast")
                    .font(AgoraTheme.buttonFont)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .buttonStyle(AgoraPillButtonStyle())
        .padding(.horizontal, 16)
        .accessibilityHint(
            hasConfiguredEpisode
                ? "Opens episode details and prompt editing"
                : "Opens podcast import"
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("AGORA\nINTERACTIVE PODCAST")
                .font(AgoraTheme.titleFont)
                .foregroundColor(AgoraTheme.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.58)
                .lineSpacing(-4)
                .layoutPriority(1)

            Spacer()
            Button {
                showPlaybackSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AgoraTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(AgoraTheme.cardSurface))
            }
            .accessibilityLabel("Playback settings")

            Button {
                showAIAccount = true
            } label: {
                Image(systemName: hasUsableAI ? "brain.head.profile.fill" : "person.badge.key.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(AgoraTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(AgoraTheme.cardSurface))
            }
            .accessibilityLabel(hasUsableAI ? "AI access ready" : "Set up AI access")
        }
        .padding(.horizontal, 20)
    }

    private var aiSetupCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "person.badge.key.fill")
                        .foregroundColor(AgoraTheme.accent)
                    Text("Connect Your AI")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)
                }
                Text("Connect a personal AI provider account. The Agora is free and never sells credits or receives payment for AI usage.")
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.inkMuted)
                Button("Connect Your AI") {
                    showAIAccount = true
                }
                .buttonStyle(AgoraPillButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    private var emptyEpisodeCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose a podcast to begin")
                    .font(AgoraTheme.cardValueFont)
                    .foregroundColor(AgoraTheme.ink)
                Text("Open the episode editor and paste an Apple Podcasts link or a direct audio link.")
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    private var pointsCard: some View {
        NavigationLink(destination: PointsProgressView()) {
            AgoraCard {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Agora Points")
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.ink)

                        Text("\(pointsStore.currentLevel.title) · \(pointsStore.totalPoints) points")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)

                        Text("View your training arc")
                            .font(AgoraTheme.bodyFont)
                            .foregroundColor(AgoraTheme.ink)
                    }

                    Spacer()

                    Image(systemName: pointsStore.currentLevel.icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(AgoraTheme.accent)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(AgoraTheme.inkMuted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Agora Points. \(pointsStore.currentLevel.title), \(pointsStore.totalPoints) points. View progress.")
        .padding(.horizontal, 16)
    }

    private var donationCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(AgoraTheme.accent)
                    Text("Keep the Public Square Open")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)
                    Spacer()
                    AgoraTag(text: "501(c)(3)")
                }

                Text("Donations support free public forums, educational resources, distinguished speakers, wider media access, and The Agora's long-term public-learning mission.")
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: AppLinks.paypalDonation) {
                    HStack {
                        Text("Donate Securely with PayPal")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                }
                .buttonStyle(AgoraPillButtonStyle())

                Text("Opens The Agora LA's secure PayPal donation page. Donations never unlock app features.")
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    private var legalLinks: some View {
        HStack(spacing: 18) {
            Link("Privacy", destination: AppLinks.privacy)
            Link("Terms", destination: AppLinks.terms)
            Link("Support", destination: AppLinks.support)
        }
        .font(AgoraTheme.tagFont.weight(.semibold))
        .foregroundColor(AgoraTheme.inkMuted)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
#Preview {
    ContentView()
        .environmentObject(PointsStore())
        .environmentObject(EpisodeStore())
        .environmentObject(AIAccountStore())
}
#endif
