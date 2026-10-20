import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum AIPowerLevel: String, CaseIterable, Identifiable {
    case balanced
    case economical
    case maximum
    case free

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: return "Balanced"
        case .economical: return "Economical"
        case .maximum: return "Maximum quality"
        case .free: return "Free model"
        }
    }

    var detail: String {
        switch self {
        case .balanced: return "Strong analysis with moderate cost"
        case .economical: return "Fastest and lowest-cost option"
        case .maximum: return "Deepest analysis at a higher cost"
        case .free: return "Open model at no charge. Scanning and grading still cost a few cents, and free capacity is rate limited."
        }
    }

    var modelID: String {
        switch self {
        case .balanced: return "openai/gpt-5.6-terra"
        case .economical: return "openai/gpt-5.6-luna"
        case .maximum: return "openai/gpt-6-astra"
        case .free: return "nvidia/nemotron-3-super-120b-a12b:free"
        }
    }
}

enum AIAccountError: LocalizedError {
    case couldNotStartSignIn
    case invalidCallback
    case invalidAPIKey
    case managementAPIKey
    case signInRejected(String)
    case keychainFailure
    case secureRandomUnavailable
    case dataSharingPermissionRequired

    var errorDescription: String? {
        switch self {
        case .dataSharingPermissionRequired:
            return "Permission is needed before sending podcast material or your answers to AI providers. Choose Allow AI & Analyze to continue."
        case .couldNotStartSignIn:
            return "The AI sign-in window could not be opened."
        case .secureRandomUnavailable:
            return "The AI sign-in could not be started securely on this device. Please try again."
        case .invalidCallback:
            return "The AI sign-in did not return a valid authorization."
        case .invalidAPIKey:
            return "That key could not be verified. Paste the complete OpenRouter API key beginning with sk-or-, then try again."
        case .managementAPIKey:
            return "That is a management key, which cannot run AI requests. Create and paste a regular OpenRouter API key instead."
        case .signInRejected(let message):
            return message
        case .keychainFailure:
            return "The secure AI connection could not be saved on this device."
        }
    }
}

@MainActor
final class AIAccountStore: NSObject, ObservableObject {
    @Published private(set) var isConnected: Bool
    @Published var allowsAIProcessing: Bool {
        didSet { AIProcessingConsent.setAllowed(allowsAIProcessing) }
    }
    @Published var powerLevel: AIPowerLevel {
        didSet { UserDefaults.standard.set(powerLevel.rawValue, forKey: Self.powerLevelKey) }
    }

    nonisolated private static let powerLevelKey = "TheAgoraLA.AI.PowerLevel"
    nonisolated private static let keychainService = "com.theagora.la.personal-ai"
    nonisolated private static let keychainAccount = "openrouter-oauth-key"
    private var webSession: ASWebAuthenticationSession?

    override init() {
        let saved = UserDefaults.standard.string(forKey: Self.powerLevelKey)
        powerLevel = AIPowerLevel(rawValue: saved ?? "") ?? .balanced
        allowsAIProcessing = Self.hasDataSharingConsent
        isConnected = Self.readAPIKey() != nil
        super.init()
        Self.migrateKeychainAccessibility()
    }

    func connect() async throws {
        guard allowsAIProcessing else { throw AIAccountError.dataSharingPermissionRequired }
        let verifier = try Self.randomVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        var components = URLComponents(string: "https://openrouter.ai/auth")
        components?.queryItems = [
            URLQueryItem(name: "callback_url", value: AppLinks.openRouterCallback.absoluteString),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizationURL = components?.url else { throw AIAccountError.couldNotStartSignIn }

        let callbackURL = try await beginWebAuthentication(at: authorizationURL)
        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw AIAccountError.invalidCallback
        }

        let key = try await exchange(code: code, verifier: verifier)
        guard Self.saveAPIKey(key) else { throw AIAccountError.keychainFailure }
        isConnected = true
    }

    func connect(usingAPIKey rawKey: String) async throws {
        guard allowsAIProcessing else { throw AIAccountError.dataSharingPermissionRequired }
        let key = rawKey
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard key.hasPrefix("sk-or-"), key.count >= 20, key.count <= 500 else {
            throw AIAccountError.invalidAPIKey
        }

        guard let url = URL(string: "https://openrouter.ai/api/v1/key") else {
            throw AIAccountError.invalidAPIKey
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIAccountError.invalidAPIKey
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AIAccountError.invalidAPIKey
            }
            let message = Self.serviceMessage(from: data) ?? "OpenRouter could not verify the key right now. Please try again."
            throw AIAccountError.signInRejected(message)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = object["data"] as? [String: Any] else {
            throw AIAccountError.invalidAPIKey
        }
        if details["is_management_key"] as? Bool == true {
            throw AIAccountError.managementAPIKey
        }
        guard Self.saveAPIKey(key) else { throw AIAccountError.keychainFailure }
        isConnected = true
    }

    func disconnect() {
        Self.deleteAPIKey()
        isConnected = false
        allowsAIProcessing = false
    }

    func refreshConnectionStatus() async {
        guard let key = Self.readAPIKey(), !key.isEmpty else {
            isConnected = false
            return
        }
        guard let url = URL(string: "https://openrouter.ai/api/v1/key") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if (200...299).contains(http.statusCode) {
                isConnected = true
            } else if http.statusCode == 401 {
                invalidateConnection()
            }
        } catch {
            // A temporary network failure does not mean the saved account was disconnected.
        }
    }

    func invalidateConnection() {
        Self.deleteAPIKey()
        isConnected = false
    }

    nonisolated static func apiKey() -> String? {
        readAPIKey()
    }

    nonisolated static var hasDataSharingConsent: Bool {
        AIProcessingConsent.isAllowed()
    }

    private nonisolated static func migrateKeychainAccessibility() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemUpdate(query as CFDictionary, [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary)
    }

    nonisolated static func selectedModelID() -> String {
        let saved = UserDefaults.standard.string(forKey: powerLevelKey)
        return (AIPowerLevel(rawValue: saved ?? "") ?? .balanced).modelID
    }

    private func beginWebAuthentication(at url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "theagorala") { [weak self] url, error in
                self?.webSession = nil
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: AIAccountError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            guard session.start() else {
                webSession = nil
                continuation.resume(throwing: AIAccountError.couldNotStartSignIn)
                return
            }
        }
    }

    private func exchange(code: String, verifier: String) async throws -> String {
        guard let url = URL(string: "https://openrouter.ai/api/v1/auth/keys") else {
            throw AIAccountError.invalidCallback
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "code": code,
            "code_verifier": verifier,
            "code_challenge_method": "S256",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = Self.serviceMessage(from: data) ?? "The AI account did not approve this connection."
            throw AIAccountError.signInRejected(message)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? String,
              !key.isEmpty else {
            throw AIAccountError.invalidCallback
        }
        return key
    }

    private nonisolated static func randomVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AIAccountError.secureRandomUnavailable
        }
        return Data(bytes).base64URLEncodedString()
    }

    private nonisolated static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    private nonisolated static func saveAPIKey(_ key: String) -> Bool {
        deleteAPIKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(key.utf8),
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private nonisolated static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private nonisolated static func serviceMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] { return error["message"] as? String }
        return object["message"] as? String
    }
}

extension AIAccountStore: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
