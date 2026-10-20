import SwiftUI

extension View {
    func aiProcessingConsent(
        isPresented: Binding<Bool>,
        allowTitle: String = "Allow AI & Analyze",
        onAllow: @escaping () -> Void,
        onCancel: @escaping () -> Void = {}
    ) -> some View {
        alert("Allow AI Processing?", isPresented: isPresented) {
            Button(allowTitle, action: onAllow)
            Button("Not Now", role: .cancel, action: onCancel)
        } message: {
            Text(AIProcessingConsent.disclosure)
        }
    }
}

#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct AgoraCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(AgoraTheme.cardGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                    )
            )
            .shadow(color: AgoraTheme.shadow, radius: 18, x: 0, y: 10)
    }
}

struct AgoraPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AgoraTheme.buttonFont)
            .foregroundColor(AgoraTheme.inkOnAccent)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(AgoraTheme.accentGradient)
                    .shadow(color: AgoraTheme.shadow, radius: 8, x: 0, y: 4)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

struct AgoraOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AgoraTheme.buttonFont)
            .foregroundColor(AgoraTheme.ink)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                    .background(
                        Capsule().fill(AgoraTheme.cardSurface)
                    )
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

struct AgoraTag: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(AgoraTheme.tagFont)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundColor(AgoraTheme.ink)
            .background(
                Capsule().fill(AgoraTheme.tagBackground)
            )
    }
}

struct AgoraExpandableText: View {
    let text: String
    var collapsedLineLimit = 6
    var expansionThreshold = 280
    var font = AgoraTheme.bodyFont
    var color = AgoraTheme.inkMuted

    @State private var isExpanded = false

    private var needsExpansion: Bool {
        text.count > expansionThreshold
            || text.split(separator: "\n", omittingEmptySubsequences: false).count > collapsedLineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if needsExpansion {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Label(
                        isExpanded ? "Show less" : "Show more",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(AgoraTheme.tagFont.weight(.semibold))
                    .foregroundColor(AgoraTheme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Collapses this text" : "Expands the full text")
            }
        }
        .onChange(of: text) { _ in
            isExpanded = false
        }
    }
}

struct AgoraBackgroundView: View {
    // Try multiple asset names so new logo sets can be picked up without code changes
    private let coverCandidates: [String] = [
        "AppLogo", // preferred new logo set name
        "AppCover",
        "Logo",
        "Cover",
        "Brand",
        "BrandLogo"
    ]

    private func findCoverImage() -> Image? {
        #if os(iOS) || os(tvOS) || os(visionOS)
        for name in coverCandidates {
            if let uiImage = UIImage(named: name) {
                return Image(uiImage: uiImage)
            }
        }
        #elseif os(macOS)
        for name in coverCandidates {
            if let nsImage = NSImage(named: name) {
                return Image(nsImage: nsImage)
            }
        }
        #endif
        return nil
    }

    var body: some View {
        ZStack {
            if let image = findCoverImage() {
                GeometryReader { proxy in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .ignoresSafeArea()
                        .overlay(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.black.opacity(0.20), Color.clear]),
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
            } else {
                fallbackBackground
            }
        }
    }

    // Previous gradient/shapes as a reusable fallback
    private var fallbackBackground: some View {
        ZStack {
            AgoraTheme.background
                .ignoresSafeArea()

            Circle()
                .fill(AgoraTheme.orbGradient)
                .frame(width: 320, height: 320)
                .blur(radius: 50)
                .offset(x: 140, y: -160)

            RoundedRectangle(cornerRadius: 80, style: .continuous)
                .fill(AgoraTheme.waveGradient)
                .frame(width: 320, height: 180)
                .blur(radius: 50)
                .rotationEffect(.degrees(-20))
                .offset(x: -160, y: 240)
        }
    }
}

extension View {
    func agoraFieldStyle() -> some View {
        self
            .font(AgoraTheme.bodyFont)
            .foregroundColor(AgoraTheme.ink)
            .tint(AgoraTheme.accent)
            .padding(12)
            .background(Color.white.opacity(0.85))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AgoraTheme.cardStroke, lineWidth: 1)
            )
    }
}
