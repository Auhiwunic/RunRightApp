import Foundation
import AuthenticationServices
import CryptoKit
import Security
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseStorage
import GoogleSignIn
import UIKit

/// Errors surfaced by the account-deletion flow so the UI can react (e.g. trigger
/// reauthentication when Firebase requires a fresh login before deleting).
enum AccountDeletionError: LocalizedError {
    case notSignedIn
    case missingConfiguration
    case cannotPresent
    /// Firebase requires a recent login before deletion. `provider` is the
    /// primary sign-in provider ("google.com", "password", …) so the caller
    /// knows how to reauthenticate.
    case requiresRecentLogin(provider: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:           return "You're not signed in."
        case .missingConfiguration:  return "Sign-in isn't configured."
        case .cannotPresent:         return "Couldn't present the sign-in screen."
        case .requiresRecentLogin:   return "Please re-confirm your sign-in to delete your account."
        }
    }
}

@MainActor
final class FirebaseAuthManager: ObservableObject {
    static let shared = FirebaseAuthManager()

    @Published private(set) var uid: String?
    @Published private(set) var isAuthenticated: Bool
    @Published private(set) var isAnonymous: Bool
    @Published var errorMessage: String?

    private var authListenerHandle: AuthStateDidChangeListenerHandle?
    private var appleSignInCoordinator: AppleSignInCoordinator?

    private init() {
        // Read the cached Firebase auth state synchronously so RootView never
        // shows the loading spinner for a returning user (prevents black flash).
        let current = Auth.auth().currentUser
        self.uid             = current?.uid
        self.isAuthenticated = current != nil
        self.isAnonymous     = current?.isAnonymous ?? false
        listenToAuthChanges()
    }

    private func listenToAuthChanges() {
        authListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.uid = user?.uid
                self.isAuthenticated = (user != nil)
                self.isAnonymous = (user?.isAnonymous ?? false)
                if user != nil { self.errorMessage = nil }
            }
        }
    }

    // MARK: - Anonymous (bootstrap)

    func signInAnonymouslyIfNeeded() async {
        guard Auth.auth().currentUser == nil else { return }
        errorMessage = nil
        do {
            _ = try await Auth.auth().signInAnonymously()
        } catch let error as NSError {
            debugLog("[FirebaseAuth] signInAnonymously failed — code: \(error.code), \(error.userInfo)")
            if error.code == AuthErrorCode.operationNotAllowed.rawValue {
                errorMessage = "Anonymous sign-in is disabled. Enable it in Firebase Console → Authentication → Sign-in method."
            } else {
                errorMessage = "Sign-in failed (code \(error.code)): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Google Sign In

    func signInWithGoogle() async {
        errorMessage = nil
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            errorMessage = "Firebase not configured. Missing client ID."
            debugLog("[GoogleSignIn] ERROR: No clientID from FirebaseApp")
            return
        }
        debugLog("[GoogleSignIn] clientID = \(clientID)")

        // Find the topmost presented view controller
        guard let rootVC = Self.topViewController() else {
            errorMessage = "Unable to present sign-in screen."
            debugLog("[GoogleSignIn] ERROR: No root VC found")
            return
        }
        debugLog("[GoogleSignIn] Presenting from: \(type(of: rootVC))")

        do {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
            debugLog("[GoogleSignIn] Sign-in returned. User: \(result.user.profile?.email ?? "nil")")
            debugLog("[GoogleSignIn] idToken present: \(result.user.idToken != nil)")

            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = "Google sign-in failed: missing ID token."
                debugLog("[GoogleSignIn] ERROR: idToken is nil")
                return
            }

            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            debugLog("[GoogleSignIn] Firebase credential created, signing in...")
            try await signInOrLink(with: credential)
            debugLog("[GoogleSignIn] Firebase sign-in SUCCESS! uid: \(Auth.auth().currentUser?.uid ?? "nil")")
        } catch {
            let nsError = error as NSError
            // User cancelled = don't show error
            if nsError.code == GIDSignInError.canceled.rawValue {
                debugLog("[GoogleSignIn] User cancelled")
                return
            }
            errorMessage = "Google sign-in failed: \(error.localizedDescription)"
            debugLog("[GoogleSignIn] ERROR: \(error)")
        }
    }

    // MARK: - Sign in with Apple

    func signInWithApple() async {
        errorMessage = nil
        do {
            let apple = try await requestAppleCredential()
            let credential = OAuthProvider.appleCredential(
                withIDToken: apple.idToken,
                rawNonce: apple.rawNonce,
                fullName: apple.fullName
            )
            try await signInOrLink(with: credential)
        } catch {
            errorMessage = "Apple sign-in failed: \(error.localizedDescription)"
        }
    }

    // Get the topmost view controller (traverses presented VCs)
    private static func topViewController() -> UIViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        else { return nil }

        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - Email / Password

    func signInWithEmail(email: String, password: String) async {
        errorMessage = nil
        do {
            let credential = EmailAuthProvider.credential(withEmail: email, password: password)
            try await signInOrLink(with: credential)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAccount(email: String, password: String) async {
        errorMessage = nil
        do {
            if let user = Auth.auth().currentUser, user.isAnonymous {
                let credential = EmailAuthProvider.credential(withEmail: email, password: password)
                try await linkAnonymousUser(user, with: credential)
            } else {
                _ = try await Auth.auth().createUser(withEmail: email, password: password)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendPasswordReset(email: String) async {
        errorMessage = nil
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sign Out

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        try? Auth.auth().signOut()
        // Local caches are device global; clear them so the next account
        // starts clean instead of inheriting this user's data.
        Self.clearLocalData()
    }

    // MARK: - Shared helpers

    func signInOrLink(with credential: AuthCredential) async throws {
        let auth = Auth.auth()
        if let user = auth.currentUser, user.isAnonymous {
            do {
                try await linkAnonymousUser(user, with: credential)
            } catch let error as NSError where
                error.code == AuthErrorCode.credentialAlreadyInUse.rawValue
                || error.code == AuthErrorCode.emailAlreadyInUse.rawValue {
                // OAuth links fail with credentialAlreadyInUse; EMAIL links fail
                // with emailAlreadyInUse. Both mean "this identity already has an
                // account" — without catching emailAlreadyInUse, every returning
                // email/password user was unable to sign in (the error propagated).
                // The credential belongs to an existing account, so linking failed
                // and guest data under the anonymous uid would be orphaned. Buffer
                // it while this session can still read it, switch accounts, then
                // merge it across. Best effort: never blocks the sign in.
                let guestData = await Self.fetchGuestData(uid: user.uid)
                _ = try await auth.signIn(with: credential)
                if let newUid = auth.currentUser?.uid, newUid != user.uid {
                    await Self.mergeGuestData(guestData, into: newUid)
                }
            }
        } else {
            _ = try await auth.signIn(with: credential)
        }
    }

    /// Snapshot of a guest account's Firestore docs, captured before the switch.
    private struct GuestData {
        var collections: [String: [(id: String, data: [String: Any])]] = [:]
        var isEmpty: Bool { collections.values.allSatisfy { $0.isEmpty } }
    }

    private static let guestCollections = ["runs", "scans", "shoes", "plans", "settings"]

    private static func fetchGuestData(uid: String) async -> GuestData {
        var out = GuestData()
        let db = Firestore.firestore()
        for name in guestCollections {
            let docs = (try? await db.collection("users").document(uid)
                .collection(name).getDocuments())?.documents ?? []
            out.collections[name] = docs.map { ($0.documentID, $0.data()) }
        }
        return out
    }

    private static func mergeGuestData(_ data: GuestData, into uid: String) async {
        guard !data.isEmpty else { return }
        let db = Firestore.firestore()
        for (name, docs) in data.collections {
            for (id, fields) in docs {
                let ref = db.collection("users").document(uid)
                    .collection(name).document(id)
                // Runs/scans/shoes carry unique IDs and are purely additive, so a
                // merge is safe. Settings/plans are singletons that the existing
                // account already owns — only carry the guest's over if the target
                // has none yet, so we never clobber a real account's profile/plan.
                if name == "settings" || name == "plans" {
                    // Fail CLOSED: only copy when we POSITIVELY confirmed the
                    // target has no such doc. `exists` is nil when the read itself
                    // failed (network hiccup in this post-account-switch window);
                    // treat anything other than a confirmed-absent doc as "skip",
                    // so a transient error never overwrites a real account's data.
                    let exists = (try? await ref.getDocument())?.exists
                    if exists != false { continue }
                }
                // Don't silently drop a guest doc on a write failure — at minimum
                // record it so a lost run/scan merge is detectable (#3).
                do {
                    try await ref.setData(fields, merge: true)
                } catch {
                    CrashReporter.record(error, context: "mergeGuestData.write.\(name)")
                }
            }
        }
    }

    private func linkAnonymousUser(_ user: User, with credential: AuthCredential) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            user.link(with: credential) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    // MARK: - Account Deletion (App Store Guideline 5.1.1(v))

    /// Permanently delete the signed-in user: wipe their Firestore + Storage data,
    /// then delete the Firebase Auth user. If Firebase requires a fresh login it
    /// throws `.requiresRecentLogin`; the caller should reauthenticate (via
    /// `reauthenticateWithGoogle()` / `reauthenticateWithEmail(password:)`) and call
    /// this again.
    func deleteAccount(reauthenticated: Bool = false) async throws {
        guard let user = Auth.auth().currentUser else { throw AccountDeletionError.notSignedIn }
        let uid = user.uid

        // Deleting the Firebase Auth user requires a recent login, but wiping the
        // user's Firestore/Storage data requires an *active* login. If we wiped
        // first and the auth deletion then failed on a stale session, the user
        // would be left with a live account whose data is already destroyed — and
        // a cancelled reauth would make that permanent. So for any real account we
        // demand a fresh reauthentication BEFORE destroying anything: the caller
        // catches this, reauthenticates, and retries with `reauthenticated: true`.
        // If the user cancels the reauth prompt, nothing has been touched.
        // Anonymous users have no credential to reauth and are deleted directly.
        if !user.isAnonymous && !reauthenticated {
            throw AccountDeletionError.requiresRecentLogin(provider: user.providerData.first?.providerID ?? "unknown")
        }

        do {
            try await Self.deleteAllUserData(uid: uid)
            try await user.delete()
        } catch let error as NSError where error.code == AuthErrorCode.requiresRecentLogin.rawValue {
            throw AccountDeletionError.requiresRecentLogin(provider: user.providerData.first?.providerID ?? "unknown")
        }

        Self.clearLocalData()
        GIDSignIn.sharedInstance.signOut()
    }

    /// Reauthenticate a Google user (re-presents Google sign-in to get a fresh token).
    func reauthenticateWithGoogle() async throws {
        guard let user = Auth.auth().currentUser else { throw AccountDeletionError.notSignedIn }
        guard let clientID = FirebaseApp.app()?.options.clientID else { throw AccountDeletionError.missingConfiguration }
        guard let rootVC = Self.topViewController() else { throw AccountDeletionError.cannotPresent }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
        guard let idToken = result.user.idToken?.tokenString else { throw AccountDeletionError.missingConfiguration }
        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: result.user.accessToken.tokenString
        )
        try await user.reauthenticate(with: credential)
    }

    /// Reauthenticate an Apple user with a fresh Apple ID token.
    func reauthenticateWithApple() async throws {
        guard let user = Auth.auth().currentUser else { throw AccountDeletionError.notSignedIn }
        let apple = try await requestAppleCredential()
        let credential = OAuthProvider.appleCredential(
            withIDToken: apple.idToken,
            rawNonce: apple.rawNonce,
            fullName: apple.fullName
        )
        try await user.reauthenticate(with: credential)
    }

    /// Reauthenticate an email/password user with their password.
    func reauthenticateWithEmail(password: String) async throws {
        guard let user = Auth.auth().currentUser, let email = user.email else { throw AccountDeletionError.notSignedIn }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        try await user.reauthenticate(with: credential)
    }

    /// Delete every Firestore document under users/{uid} plus the user's Storage
    /// folder. The Firestore client SDK can't recurse subcollections, so each
    /// known subcollection is enumerated and batch-deleted.
    private static func deleteAllUserData(uid: String) async throws {
        let db = Firestore.firestore()
        let userDoc = db.collection("users").document(uid)
        for sub in ["runs", "scans", "shoes", "plans", "settings"] {
            try await deleteCollection(userDoc.collection(sub))
        }
        try await userDoc.delete()
        // Storage: users/{uid}/... (e.g. scans/{shoe}/{file}.jpg).
        try await deleteStorageFolder(path: "users/\(uid)")
    }

    private static func deleteCollection(_ collection: CollectionReference, batchSize: Int = 100) async throws {
        while true {
            let snapshot = try await collection.limit(to: batchSize).getDocuments()
            guard !snapshot.documents.isEmpty else { break }
            let batch = collection.firestore.batch()
            snapshot.documents.forEach { batch.deleteDocument($0.reference) }
            try await batch.commit()
            if snapshot.documents.count < batchSize { break }
        }
    }

    private static func deleteStorageFolder(path: String) async throws {
        let ref = Storage.storage().reference(withPath: path)
        let list = try await ref.listAll()
        // Attempt every file and subfolder, but do NOT swallow failures — a
        // silently-skipped delete leaves the user's photos in Storage while
        // deletion reports success, violating 5.1.1(v). Surface the first failure
        // so the caller reports incompleteness; a retry re-lists and finishes (#1).
        var firstError: Error?
        for item in list.items {
            do { try await item.delete() }
            catch { if firstError == nil { firstError = error } }
        }
        for prefix in list.prefixes {
            do { try await deleteStorageFolder(path: prefix.fullPath) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private static func clearLocalData() {
        AnalysisHistoryStore.shared.clearAll()   // history + raw CSV exports
        ScorecardDataStore.shared.clear()
        ConsentManager.shared.clear()
    }

    private func requestAppleCredential() async throws -> AppleCredentialResult {
        try await withCheckedThrowingContinuation { continuation in
            let rawNonce = Self.randomNonceString()
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = Self.sha256(rawNonce)

            let coordinator = AppleSignInCoordinator(rawNonce: rawNonce) { [weak self] result in
                self?.appleSignInCoordinator = nil
                continuation.resume(with: result)
            }
            appleSignInCoordinator = coordinator
            coordinator.perform(request: request)
        }
    }

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            if status != errSecSuccess {
                fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(status)")
            }

            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }

        return result
    }

    private static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.compactMap { String(format: "%02x", $0) }.joined()
    }
}

private struct AppleCredentialResult {
    let idToken: String
    let rawNonce: String
    let fullName: PersonNameComponents?
}

private final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let rawNonce: String
    private let completion: (Result<AppleCredentialResult, Error>) -> Void

    init(rawNonce: String, completion: @escaping (Result<AppleCredentialResult, Error>) -> Void) {
        self.rawNonce = rawNonce
        self.completion = completion
    }

    func perform(request: ASAuthorizationAppleIDRequest) {
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard
            let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = appleIDCredential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8)
        else {
            completion(.failure(AccountDeletionError.missingConfiguration))
            return
        }

        completion(.success(AppleCredentialResult(
            idToken: idToken,
            rawNonce: rawNonce,
            fullName: appleIDCredential.fullName
        )))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        completion(.failure(error))
    }
}
