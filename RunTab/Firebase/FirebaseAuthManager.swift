import Foundation
import FirebaseAuth

@MainActor
final class FirebaseAuthManager: ObservableObject {
    static let shared = FirebaseAuthManager()

    @Published private(set) var uid: String?
    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var isAnonymous: Bool = false
    @Published var errorMessage: String?

    private var authListenerHandle: AuthStateDidChangeListenerHandle?

    private init() {
        listenToAuthChanges()
    }

    private func listenToAuthChanges() {
        // The singleton lives for the app's lifetime, so the listener
        // naturally stays alive as well. No cleanup needed.
        authListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.uid = user?.uid
                self.isAuthenticated = (user != nil)
                self.isAnonymous = (user?.isAnonymous ?? false)
                // Clear any stale error when auth state resolves successfully.
                if user != nil {
                    self.errorMessage = nil
                }
            }
        }
    }

    func signInAnonymouslyIfNeeded() async {
        guard Auth.auth().currentUser == nil else { return }
        errorMessage = nil
        do {
            _ = try await Auth.auth().signInAnonymously()
        } catch let error as NSError {
            // Log the full error for debugging in the Xcode console.
            print("[FirebaseAuth] signInAnonymously failed — domain: \(error.domain), code: \(error.code), detail: \(error.userInfo)")

            // Show a human-readable message in the UI.
            if error.code == AuthErrorCode.operationNotAllowed.rawValue {
                self.errorMessage = "Anonymous sign-in is not enabled. Please enable it in the Firebase Console under Authentication → Sign-in method."
            } else {
                self.errorMessage = "Sign-in failed (code \(error.code)): \(error.localizedDescription)"
            }
        }
    }

    func signInWithApple() async throws {
        guard let currentNonce = AppleSignInNonceHolder.nonce else {
            throw NSError(domain: "AppleSignIn", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing nonce"])
        }

        // The credential is created inside the Apple sign-in completion, so this method is not used directly.
        // Kept for future refactors.
        _ = currentNonce
    }

    func signInOrLink(with credential: AuthCredential) async throws {
        let auth = Auth.auth()

        if let user = auth.currentUser, user.isAnonymous {
            try await linkAnonymousUser(user, with: credential)
        } else {
            _ = try await auth.signIn(with: credential)
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
    }

    private func linkAnonymousUser(_ user: User, with credential: AuthCredential) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            user.link(with: credential) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

/// Thread-safe holder for the raw nonce used during Apple sign-in.
/// Firebase needs the raw nonce later to validate the identity token.
final class AppleSignInNonceHolder: @unchecked Sendable {
    private static let lock = NSLock()
    private static var _nonce: String?

    static var nonce: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _nonce
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _nonce = newValue
        }
    }

    /// Clear the nonce after use to avoid stale values.
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        _nonce = nil
    }
}
