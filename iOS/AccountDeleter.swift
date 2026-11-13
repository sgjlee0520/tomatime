// App Store 5.1.1(v): "Delete Account" inside the app. Sign in with Apple again (a fresh credential and its
// authorization code), revoke Tomatime's Sign in with Apple token, then the server (firebase/functions/account.js)
// takes the person out of every group and deletes their name, shared timer, device tokens and sign-in.
import AuthenticationServices
import CryptoKit
import FirebaseAuth
import FirebaseCore
import UIKit

@MainActor final class AccountDeleter: NSObject {
    private var pending: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    private var nonce = ""

    func run() async throws {
        guard let user = Auth.auth().currentUser else { return }
        let apple = try await appleCredential()
        guard let token = apple.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
              let code = apple.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw URLError(.userAuthenticationRequired)
        }
        try await user.reauthenticate(with: OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce, fullName: nil))
        try await Auth.auth().revokeToken(withAuthorizationCode: code)
        let idToken = try await user.getIDToken()
        let project = FirebaseApp.app()?.options.projectID ?? ""
        var request = URLRequest(url: URL(string: "https://us-central1-\(project).cloudfunctions.net/deleteAccount")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        try? Auth.auth().signOut()
    }

    private func appleCredential() async throws -> ASAuthorizationAppleIDCredential {
        nonce = UUID().uuidString + UUID().uuidString
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { c in
            pending = c
            controller.performRequests()
        }
    }
}

extension AccountDeleter: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    nonisolated func authorizationController(controller _: ASAuthorizationController, didCompleteWithAuthorization auth: ASAuthorization) {
        MainActor.assumeIsolated {
            if let apple = auth.credential as? ASAuthorizationAppleIDCredential { pending?.resume(returning: apple) }
            else { pending?.resume(throwing: URLError(.userAuthenticationRequired)) }
            pending = nil
        }
    }
    nonisolated func authorizationController(controller _: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated { pending?.resume(throwing: error); pending = nil }
    }
    nonisolated func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? UIWindow()
        }
    }
}
