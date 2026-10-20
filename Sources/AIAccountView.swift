import AuthenticationServices
import SwiftUI
import UIKit

private enum AISetupStage: Int, CaseIterable {
    case connect = 1
    case quality = 2
    case complete = 3

    var shortTitle: String {
        switch self {
        case .connect: return "Connect"
        case .quality: return "Quality"
        case .complete: return "Ready"
        }
    }
}

struct AIAccountView: View {
    @EnvironmentObject private var providerAccount: AIAccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var stage: AISetupStage = .connect
    @State private var hasInitializedStage = false
    @State private var isConnectingProvider = false
    @State private var isVerifyingAPIKey = false
    @State private var showsAPIKeyEntry = false
    @State private var apiKey = ""
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var showAIProcessingConsent = false
    @State private var consentForAPIKey = false
    @State private var cloudDataMessage = ""
    @State private var confirmCloudDeletion = false
    @FocusState private var isAPIKeyFocused: Bool

    var body: some View {
        NavigationView {
            ZStack {
                AgoraBackgroundView()
                ScrollView {
                    VStack(spacing: 18) {
                        progressCard
                        privacyCard

                        switch stage {
                        case .connect:
                            connectionCard
                        case .quality:
                            qualityCard
                        case .complete:
                            completionCard
                        }

                    }
                    .padding(16)
                }
            }
            .navigationTitle("AI Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                guard !hasInitializedStage else { return }
                stage = providerAccount.isConnected ? .complete : .connect
                hasInitializedStage = true
            }
            .alert("Could Not Connect", isPresented: $showError) {
                Button(showsAPIKeyEntry ? "Review Key" : "Try Again") {
                    if showsAPIKeyEntry {
                        isAPIKeyFocused = true
                    } else {
                        Task { await connectProvider() }
                    }
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
            .aiProcessingConsent(isPresented: $showAIProcessingConsent, allowTitle: "Allow AI & Connect") {
                providerAccount.allowsAIProcessing = true
                Task { @MainActor in
                    await Task.yield()
                    if consentForAPIKey { await connectAPIKey() }
                    else { await connectProvider() }
                }
            }
            .confirmationDialog("Delete cloud data and cancel unfinished cloud jobs? Saved episodes on this phone will stay.", isPresented: $confirmCloudDeletion, titleVisibility: .visible) {
                Button("Delete Cloud Data", role: .destructive) {
                    Task {
                        do {
                            try await CloudAnalysisClient().deleteCloudData()
                            cloudDataMessage = "Cloud data deleted. Saved episodes on this phone are unchanged."
                        } catch { cloudDataMessage = error.localizedDescription }
                    }
                }
                Button("Keep My Data", role: .cancel) {}
            }
        }
        .navigationViewStyle(.stack)
    }

    private var progressCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Step \(stage.rawValue) of 3")
                        .font(AgoraTheme.tagFont.weight(.bold))
                        .foregroundColor(AgoraTheme.accent)
                    Spacer()
                    Text(stage.shortTitle)
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }

                HStack(spacing: 8) {
                    ForEach(AISetupStage.allCases, id: \.rawValue) { item in
                        VStack(spacing: 7) {
                            ZStack {
                                Circle()
                                    .fill(progressColor(for: item))
                                    .frame(width: 34, height: 34)
                                if item.rawValue < stage.rawValue || stage == .complete {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.white)
                                } else {
                                    Text("\(item.rawValue)")
                                        .font(AgoraTheme.tagFont.weight(.bold))
                                        .foregroundColor(item == stage ? .white : AgoraTheme.inkMuted)
                                }
                            }
                            Text(item.shortTitle)
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(item.rawValue <= stage.rawValue ? AgoraTheme.ink : AgoraTheme.inkMuted)
                        }

                        if item != .complete {
                            Rectangle()
                                .fill(item.rawValue < stage.rawValue ? AgoraTheme.accent : AgoraTheme.cardStroke)
                                .frame(height: 2)
                                .padding(.bottom, 25)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("AI setup, step \(stage.rawValue) of 3: \(stage.shortTitle)")
            }
        }
    }

    private var connectionCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect Your AI Account")
                    .font(AgoraTheme.cardValueFont)
                    .foregroundColor(AgoraTheme.ink)

                Text("Choose the path that matches what you see. Automatic connection is recommended, and an existing API key can be connected here without starting over.")
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.inkMuted)

                SetupInstructionRow(
                    number: 1,
                    title: "Open secure sign-in",
                    detail: "Sign in to the OpenRouter account that should pay for AI usage."
                )
                SetupInstructionRow(
                    number: 2,
                    title: "Approve the connection",
                    detail: "OpenRouter creates a dedicated key for The Agora."
                )
                SetupInstructionRow(
                    number: 3,
                    title: "Return automatically",
                    detail: "After approval, this screen advances to analysis quality."
                )

                if isConnectingProvider {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Waiting for OpenRouter approval...")
                            .font(AgoraTheme.bodyFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
                } else {
                    Button("Connect Automatically") {
                        Task { await connectProvider() }
                    }
                    .buttonStyle(AgoraPillButtonStyle())
                    .accessibilityHint("Opens OpenRouter and returns here after approval")
                }

                HStack(spacing: 12) {
                    Rectangle()
                        .fill(AgoraTheme.cardStroke)
                        .frame(height: 1)
                    Text("OR")
                        .font(AgoraTheme.tagFont.weight(.bold))
                        .foregroundColor(AgoraTheme.inkMuted)
                    Rectangle()
                        .fill(AgoraTheme.cardStroke)
                        .frame(height: 1)
                }

                Button(showsAPIKeyEntry ? "Hide API Key Entry" : "I Already Have an API Key") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsAPIKeyEntry.toggle()
                    }
                    if showsAPIKeyEntry {
                        isAPIKeyFocused = true
                    }
                }
                .font(AgoraTheme.bodyFont.weight(.semibold))
                .foregroundColor(AgoraTheme.accent)
                .frame(maxWidth: .infinity)

                if showsAPIKeyEntry {
                    apiKeyEntry
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Text("The Agora is free. If the provider charges for usage, you pay the provider directly and The Agora receives nothing.")
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var apiKeyEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Finish with the key you created", systemImage: "key.fill")
                .font(AgoraTheme.bodyFont.weight(.semibold))
                .foregroundColor(AgoraTheme.ink)

            Text("Paste the complete regular OpenRouter key. The Agora verifies it before storing it securely in this iPhone's Keychain.")
                .font(AgoraTheme.tagFont)
                .foregroundColor(AgoraTheme.inkMuted)

            SecureField("sk-or-v1-...", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .focused($isAPIKeyFocused)
                .padding(12)
                .background(Color.white.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                )
                .cornerRadius(12)
                .accessibilityLabel("OpenRouter API key")

            Button {
                if let pasted = UIPasteboard.general.string {
                    apiKey = pasted
                }
            } label: {
                Label("Paste Key from Clipboard", systemImage: "doc.on.clipboard")
            }
            .font(AgoraTheme.tagFont.weight(.semibold))
            .foregroundColor(AgoraTheme.accent)

            if isVerifyingAPIKey {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Verifying securely...")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }
                .frame(maxWidth: .infinity)
            } else {
                Button("Verify & Connect") {
                    Task { await connectAPIKey() }
                }
                .buttonStyle(AgoraPillButtonStyle())
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Text("Need to create another key?")
                    .foregroundColor(AgoraTheme.inkMuted)
                Link("Open API Keys", destination: AppLinks.providerKeys)
                    .foregroundColor(AgoraTheme.accent)
            }
            .font(AgoraTheme.tagFont)
        }
        .padding(14)
        .background(AgoraTheme.accent.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AgoraTheme.accent.opacity(0.28), lineWidth: 1)
        )
        .cornerRadius(14)
    }

    private var qualityCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 14) {
                Label("Account Connected", systemImage: "checkmark.shield.fill")
                    .font(AgoraTheme.tagFont.weight(.bold))
                    .foregroundColor(AgoraTheme.accent)

                Text("Choose Analysis Quality")
                    .font(AgoraTheme.cardValueFont)
                    .foregroundColor(AgoraTheme.ink)

                Text("Balanced is recommended for most listeners. You can change this later from AI Setup.")
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.inkMuted)

                ForEach(AIPowerLevel.allCases) { level in
                    qualityOption(level)
                }

                Button("Continue with \(providerAccount.powerLevel.title)") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        stage = .complete
                    }
                }
                .buttonStyle(AgoraPillButtonStyle())

                Button("Disconnect and Start Over", role: .destructive) {
                    providerAccount.disconnect()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        stage = .connect
                    }
                }
                .font(AgoraTheme.tagFont.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var completionCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundColor(AgoraTheme.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your AI Is Ready")
                            .font(AgoraTheme.cardValueFont)
                            .foregroundColor(AgoraTheme.ink)
                        Text("Setup is complete")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }
                }

                SetupCheckRow(text: "Secure provider account connected")
                SetupCheckRow(text: "\(providerAccount.powerLevel.title) analysis selected")
                SetupCheckRow(text: "Provider billing stays separate from The Agora")

                Text("Before analyzing a long episode, make sure your provider account has available credits. You can return here anytime.")
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)

                Button("Return to The Agora") {
                    dismiss()
                }
                .buttonStyle(AgoraPillButtonStyle())

                HStack {
                    Button("Change Quality") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            stage = .quality
                        }
                    }
                    Spacer()
                    Link("Provider Credits", destination: AppLinks.providerCredits)
                }
                .font(AgoraTheme.tagFont.weight(.semibold))
                .tint(AgoraTheme.accent)

                Button("Disconnect AI Account", role: .destructive) {
                    providerAccount.disconnect()
                    withAnimation(.easeInOut(duration: 0.25)) {
                        stage = .connect
                    }
                }
                .font(AgoraTheme.tagFont.weight(.semibold))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var privacyCard: some View {
        AgoraCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Secure and Listener-Controlled", systemImage: "lock.shield.fill")
                    .font(AgoraTheme.cardTitleFont)
                    .foregroundColor(AgoraTheme.ink)
                Toggle("Allow AI processing", isOn: $providerAccount.allowsAIProcessing)
                    .tint(AgoraTheme.accent)
                Text(AIProcessingConsent.disclosure)
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.inkMuted)

                HStack(spacing: 16) {
                    Link("Privacy", destination: AppLinks.privacy)
                    Link("Terms", destination: AppLinks.terms)
                    Link("Support", destination: AppLinks.support)
                }
                .font(AgoraTheme.tagFont.weight(.semibold))
                .tint(AgoraTheme.accent)
                if CloudAnalysisClient.isConfigured {
                    Button("Delete My Cloud Data", role: .destructive) {
                        confirmCloudDeletion = true
                    }
                    .font(AgoraTheme.tagFont)
                    if !cloudDataMessage.isEmpty {
                        Text(cloudDataMessage).font(AgoraTheme.tagFont).foregroundColor(AgoraTheme.inkMuted)
                    }
                }
            }
        }
    }

    private func progressColor(for item: AISetupStage) -> Color {
        item.rawValue <= stage.rawValue ? AgoraTheme.accent : Color.white.opacity(0.75)
    }

    private func qualityOption(_ level: AIPowerLevel) -> some View {
        Button {
            providerAccount.powerLevel = level
        } label: {
            HStack(spacing: 12) {
                Image(systemName: providerAccount.powerLevel == level ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(AgoraTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(level.title)
                            .font(AgoraTheme.bodyFont.weight(.semibold))
                            .foregroundColor(AgoraTheme.ink)
                        if level == .balanced {
                            Text("RECOMMENDED")
                                .font(AgoraTheme.tagFont.weight(.bold))
                                .foregroundColor(AgoraTheme.accent)
                        }
                    }
                    Text(level.detail)
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                }
                Spacer()
            }
            .padding(12)
            .background(providerAccount.powerLevel == level ? AgoraTheme.accent.opacity(0.1) : Color.white.opacity(0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(providerAccount.powerLevel == level ? AgoraTheme.accent : AgoraTheme.cardStroke, lineWidth: 1)
            )
            .cornerRadius(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(level.title), \(level.detail)\(level == .balanced ? ", recommended" : "")")
        .accessibilityAddTraits(providerAccount.powerLevel == level ? .isSelected : [])
    }

    @MainActor
    private func connectProvider() async {
        guard providerAccount.allowsAIProcessing else {
            consentForAPIKey = false
            showAIProcessingConsent = true
            return
        }
        guard !isConnectingProvider else { return }
        isConnectingProvider = true
        defer { isConnectingProvider = false }
        do {
            try await providerAccount.connect()
            withAnimation(.easeInOut(duration: 0.25)) {
                stage = .quality
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch let error as URLError {
            errorMessage = error.code == .notConnectedToInternet
                ? "Connect to the internet, then choose Try Again."
                : "The secure provider page could not be reached. Check your connection and try again."
            showError = true
        } catch {
            errorMessage = "The connection was not completed. No account changes were made. Choose Try Again when you are ready."
            showError = true
        }
    }

    @MainActor
    private func connectAPIKey() async {
        guard providerAccount.allowsAIProcessing else {
            consentForAPIKey = true
            isAPIKeyFocused = false
            showAIProcessingConsent = true
            return
        }
        guard !isVerifyingAPIKey else { return }
        isAPIKeyFocused = false
        isVerifyingAPIKey = true
        defer { isVerifyingAPIKey = false }
        do {
            try await providerAccount.connect(usingAPIKey: apiKey)
            apiKey = ""
            withAnimation(.easeInOut(duration: 0.25)) {
                stage = .quality
            }
        } catch let error as URLError {
            errorMessage = error.code == .notConnectedToInternet
                ? "Connect to the internet, then verify the key again."
                : "OpenRouter could not be reached. Check your connection and try again."
            showError = true
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

private struct SetupInstructionRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(AgoraTheme.tagFont.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(AgoraTheme.accent)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AgoraTheme.bodyFont.weight(.semibold))
                    .foregroundColor(AgoraTheme.ink)
                Text(detail)
                    .font(AgoraTheme.tagFont)
                    .foregroundColor(AgoraTheme.inkMuted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SetupCheckRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(AgoraTheme.bodyFont)
            .foregroundColor(AgoraTheme.ink)
            .labelStyle(.titleAndIcon)
    }
}
