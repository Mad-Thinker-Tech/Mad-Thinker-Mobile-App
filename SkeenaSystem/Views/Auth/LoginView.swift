// Bend Fly Shop

import Foundation
import LocalAuthentication
import SwiftUI

struct LoginView: View {
  @StateObject private var auth = AuthService.shared

  @State private var email: String = ""
  @State private var password: String = ""
  @State private var isBusy = false
  @State private var errorText: String?

  @State private var showRegistration = false
  @State private var showPasswordReset = false
  @FocusState private var focusedField: Field?

  @State private var isBiometricAvailable: Bool = BiometricAuth.shared.canUseBiometrics

  private enum Field { case email, password }

  // Re-export the shared helper so the existing log line below keeps working
  // without changing its shape. New call sites should just use `AlphaBadge`
  // (which self-gates).
  private var isBetaRelease: Bool { AlphaBadge.isBetaRelease }

  private var canUseBiometricsForLogin: Bool {
    isBiometricAvailable && (auth.hasStoredSession || auth.hasOfflineCredentials)
  }

  var body: some View {
    NavigationView {
      ScrollView {
        VStack(spacing: 16) {
          Spacer(minLength: 24)

          VStack(spacing: 8) {
            Image("MadThinkerLogo")
              .resizable()
              .scaledToFit()
              .frame(width: 180, height: 180)
              .clipShape(RoundedRectangle(cornerRadius: 24))
              .shadow(radius: 10)
              .padding(.bottom, 6)

          }
          .padding(.bottom, 8)

          // Need an account?
          HStack(spacing: 6) {
            Text("Need an account?")
              .foregroundColor(.brandTextSecondary)

            Button {
              showRegistration = true
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "person.badge.plus")
                Text("Create one")
              }
              .font(.brandFootnote.weight(.semibold))
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(Color.brandAccent)
              .foregroundColor(.brandTextPrimary)
              .clipShape(Capsule())
            }
            .accessibilityIdentifier("createAccountButton")
          }
          .padding(.horizontal)

          // Form
          VStack(spacing: 12) {
            TextField("Email", text: $email)
              .textInputAutocapitalization(.never)
              .keyboardType(.emailAddress)
              .autocorrectionDisabled()
              .textContentType(.username)
              .padding()
              .background(Color.brandSurface, in: RoundedRectangle(cornerRadius: 12))
              .foregroundColor(.brandTextPrimary)
              .focused($focusedField, equals: .email)
              .submitLabel(.next)
              .onSubmit { focusedField = .password }
              .accessibilityIdentifier("emailTextField")

            SecureField("Password", text: $password)
              .textContentType(.password)
              .padding()
              .background(Color.brandSurface, in: RoundedRectangle(cornerRadius: 12))
              .foregroundColor(.brandTextPrimary)
              .focused($focusedField, equals: .password)
              .submitLabel(.go)
              .onSubmit { Task { await loginTapped() } }
              .accessibilityIdentifier("passwordTextField")

            if let err = errorText {
              Text(err)
                .font(.brandFootnote)
                .foregroundColor(.brandError)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("loginErrorLabel")
            }

            policyAgreementText

            Button(action: { Task { await loginTapped() } }) {
              HStack {
                if isBusy { ProgressView().tint(.white) }
                Text(isBusy ? "Signing in…" : "Sign in")
                  .bold()
              }
              .frame(maxWidth: .infinity)
              .padding()
              .background(isFormValid ? Color.brandAccent : Color.brandStrokeStrong)
              .foregroundColor(.brandTextPrimary)
              .cornerRadius(12)
              .animation(.easeInOut(duration: 0.2), value: isFormValid)
            }
            .disabled(!isFormValid || isBusy)
            .accessibilityIdentifier("signInButton")

            // Face ID / Touch ID login
            if canUseBiometricsForLogin {
              Button {
                Task { await biometricLoginTapped() }
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: "faceid")
                  Text("Sign in with Face ID")
                    .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
              }
              .padding(.top, 4)
            }

            Button {
              showPasswordReset = true
            } label: {
              Text("Forgot password?")
                .font(.brandFootnote)
                .underline()
                .foregroundColor(.brandTextPrimary.opacity(0.8))
            }
            .padding(.top, 4)
            .accessibilityIdentifier("forgotPasswordButton")
          }
          .padding(.horizontal)

          Spacer()

          // Footer
          VStack(spacing: 8) {
            Text("Powered by Mad Thinker, Inc 2026")
              .font(.brandFootnote)
              .foregroundColor(.brandTextSecondary.opacity(0.8))
              .multilineTextAlignment(.center)
              .padding(.top, 4)
          }
          .padding(.horizontal)
          .padding(.bottom, 16)
        }
        .padding(.top, 8)
      }
      .background(Color.brandBackground.ignoresSafeArea())
      .navigationBarTitleDisplayMode(.inline)
      .navigationTitle("")
      .onTapGesture {
        // Dismiss keyboard when tapping anywhere outside the fields
        focusedField = nil
      }
      .modifier(ScrollDismissesKeyboardIfAvailable())
      .sheet(isPresented: $showRegistration) {
        NavigationView {
          MemberRegistrationView()
            .navigationTitle("Guide Registration")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
      }
      .sheet(isPresented: $showPasswordReset) {
        PasswordResetSheet(initialEmail: email.trimmingCharacters(in: .whitespaces))
      }
      .task {
        isBiometricAvailable = BiometricAuth.shared.canUseBiometrics
        await logCurrentJWT(context: "onAppear")
        if UserDefaults.standard.object(forKey: "OfflineRememberMeEnabled") == nil {
          AuthService.shared.rememberMeEnabled = true
        }
        AppLogging.log({ "[LoginView] BETA_RELEASE=\(isBetaRelease)" }, level: .debug, category: .auth)
      }
    }
    .overlay(alignment: .topLeading) {
      // Was the blue "Pilot" capsule — now a small grey "Alpha" tag. The
      // badge self-gates on BETA_RELEASE, so the surrounding overlay always
      // renders but contributes nothing visible in release builds.
      HStack {
        AlphaBadge()
          .padding(.leading, 12)
          .padding(.top, 12)
        Spacer(minLength: 0)
      }
      .zIndex(1000)
    }
    .preferredColorScheme(.dark)
  }

  @ViewBuilder
  private var policyAgreementText: some View {
    VStack(spacing: 2) {
      Text("By logging in, you agree to our")
        .font(.brandCaption)
        .foregroundColor(.brandTextSecondary)
      HStack(spacing: 4) {
        Link("Privacy Policy", destination: LegalURLs.privacyPolicy)
          .font(.brandCaption.weight(.semibold))
          .foregroundColor(.brandAccent)
        Text("and")
          .font(.brandCaption)
          .foregroundColor(.brandTextSecondary)
        Link("Acceptable Use Policy", destination: LegalURLs.acceptableUsePolicy)
          .font(.brandCaption.weight(.semibold))
          .foregroundColor(.brandAccent)
      }
    }
    .multilineTextAlignment(.center)
    .padding(.horizontal)
    .accessibilityIdentifier("loginPolicyAgreement")
  }

  // MARK: - Actions

  private var isFormValid: Bool {
    let emailPattern = #"^\S+@\S+\.\S+$"#
    let emailIsValid = email.range(of: emailPattern, options: .regularExpression) != nil
    return emailIsValid && password.count >= 6
  }

  private func loginTapped() async {
    guard !email.isEmpty, !password.isEmpty else {
      errorText = "Please enter email and password."
      return
    }
    errorText = nil
    isBusy = true
    do {
      try await auth.signIn(
        email: email.trimmingCharacters(in: .whitespaces),
        password: password
      )
      // After successful sign in, log the JWT we will use elsewhere
      await logCurrentJWT(context: "post-sign-in")
    } catch {
      errorText = error.localizedDescription
    }
    isBusy = false
  }

  private func biometricLoginTapped() async {
    errorText = nil
    isBusy = true
    defer { isBusy = false }

    do {
      // 1) System Face ID / Touch ID prompt via centralized BiometricAuth
      let ctx = try await BiometricAuth.shared.authenticateContext()

      // 2) Delegate session logic (resume/online/offline) to AuthService, passing the LAContext
      let result = await auth.biometricLoginAfterAuth(authenticationContext: ctx)
      switch result {
      case .resumedSession:
        await logCurrentJWT(context: "post-biometric-sign-in (resumed)")
      case .signedInOnline:
        await logCurrentJWT(context: "post-biometric-sign-in (online)")
      case .signedInOffline:
        // Offline path: no token to log, but we can log state
        AppLogging.log({ "Biometric offline sign-in used cached profile." }, level: .debug, category: .auth)
      case .noCredentials:
        errorText = "Unable to resume your session. Please sign in with email and password."
      case .authFailed(let msg):
        errorText = msg
      }

    } catch let bErr as BiometricAuthError {
      switch bErr {
      case .notAvailable:
        errorText = "Face ID is not available on this device."
      case .failed:
        errorText = "Face ID failed. Please try again or sign in with your password."
      }
    } catch let error as NSError {
      // LAError codes are NSError-based; preserve your previous logic
      if error.domain == LAError.errorDomain,
         error.code == LAError.userCancel.rawValue || error.code == LAError.systemCancel.rawValue {
        errorText = "Face ID was cancelled."
      } else if error.domain == LAError.errorDomain,
                error.code == LAError.biometryNotAvailable.rawValue ||
                 error.code == LAError.biometryNotEnrolled.rawValue {
        errorText = "Face ID is not available on this device."
      } else {
        errorText = "Face ID failed. Please try again or sign in with your password."
      }
    } catch {
      errorText = "Face ID failed. Please try again or sign in with your password."
    }
  }

  // MARK: - JWT Logging

  private func logCurrentJWT(context: String) async {
    // Ask AuthService for a valid token (it may use access or refresh)
    let token = await auth.currentAccessToken()
    let tokenStr = token ?? ""

    let hasToken = !tokenStr.isEmpty
    let len = tokenStr.count
    let prefix = String(tokenStr.prefix(24))

    // Add token source diagnostics
    let accessTokenPrefix = String(AuthService.shared.getStoredAccessToken()?.prefix(24) ?? "")
    let refreshTokenPrefix = String(AuthService.shared.getStoredRefreshToken()?.prefix(24) ?? "")

    AppLogging.log({ "context=\(context) hasToken=\(hasToken) len=\(len) prefix=\(prefix)" }, level: .debug, category: .auth)
    AppLogging.log({ "storedAccessToken prefix=\(accessTokenPrefix)" }, level: .debug, category: .auth)
    AppLogging.log({ "storedRefreshToken prefix=\(refreshTokenPrefix)" }, level: .debug, category: .auth)

    guard hasToken else {
      AppLogging.log({ "⚠️ No token returned from AuthService" }, level: .warn, category: .auth)
      return
    }

    // Decode header & payload safely
    let (hdr, pld) = decodeJWTParts(tokenStr)
    AppLogging.log({ "header: \(hdr)" }, level: .debug, category: .auth)
    AppLogging.log({ "payload: \(pld)" }, level: .debug, category: .auth)

    // Pull member_id from payload JSON
    let memberIdFromPayload = extractMemberId(fromPayloadJSON: pld) ?? "<nil>"
    let authMemberId = auth.currentMemberId ?? "<nil>"
    AppLogging.log({ "member_id(payload)=\(memberIdFromPayload) | AuthService.currentMemberId=\(authMemberId)" }, level: .debug, category: .auth)

    // Quick mismatch signal
    if memberIdFromPayload != authMemberId {
      AppLogging.log({ "member_id mismatch between JWT payload and AuthService cache" }, level: .warn, category: .auth)
    }
  }

  /// Decode header & payload parts of a JWT into pretty JSON.
  private func decodeJWTParts(_ jwt: String) -> (String, String) {
    let raw = jwt.lowercased().hasPrefix("bearer ") ? String(jwt.dropFirst(7)) : jwt
    let parts = raw.split(separator: ".")
    guard parts.count >= 2 else { return ("<malformed>", "<malformed>") }

    func decodePart(_ s: Substring) -> String {
      var b64 = s.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
      while b64.count % 4 != 0 {
        b64 += "="
      }
      guard let data = Data(base64Encoded: b64) else { return "<decode-failed>" }
      if let obj = try? JSONSerialization.jsonObject(with: data),
         let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
         let str = String(data: pretty, encoding: .utf8) {
        return str
      }
      return String(data: data, encoding: .utf8) ?? "<non-utf8>"
    }

    return (decodePart(parts[0]), decodePart(parts[1]))
  }

  /// Extracts `member_id` from JWT payload JSON, with fallback to legacy `angler_number`.
  private func extractMemberId(fromPayloadJSON json: String) -> String? {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

    if let um = obj["user_metadata"] as? [String: Any] {
      if let mid = um["member_id"] as? String ?? um["angler_number"] as? String ?? um["anglerNumber"] as? String {
        return mid
      }
    }

    return nil
  }
}

private struct ScrollDismissesKeyboardIfAvailable: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 16.0, *) {
      content.scrollDismissesKeyboard(.interactively)
    } else {
      content
    }
  }
}
