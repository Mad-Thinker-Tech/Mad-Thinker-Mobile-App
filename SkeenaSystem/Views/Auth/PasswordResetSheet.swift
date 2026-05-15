// Bend Fly Shop
//
// Password reset is presented as a half-height sheet from LoginView's
// "Forgot password?" link, replacing an earlier inline flow that required
// the user to fill in the main email field (and visually armed the Sign in
// button as a side effect). This sheet asks for the email independently,
// auto-populating from the login form if it's already filled in.
//
// Two visual states:
//   - Form: email field + "Reset Password" submit.
//   - Success: confirmation copy + Close button. Hit when AuthService's
//     /auth/v1/recover call returns 2xx. Backend doesn't disclose whether
//     the address is registered (anti-enumeration), so success here just
//     means the request was accepted; the message intentionally says
//     "check your email" rather than promising delivery.

import SwiftUI

struct PasswordResetSheet: View {
  @Environment(\.dismiss) private var dismiss

  /// Pre-fill from the login form when present.
  let initialEmail: String

  @State private var email: String
  @State private var isBusy = false
  @State private var errorText: String?
  /// Non-nil after a successful submit; swaps the body to the confirmation
  /// state and captures the address we sent to so the message can echo it.
  @State private var sentToEmail: String?
  @FocusState private var emailFocused: Bool

  init(initialEmail: String) {
    self.initialEmail = initialEmail
    _email = State(initialValue: initialEmail)
  }

  private var isEmailValid: Bool {
    let pattern = #"^\S+@\S+\.\S+$"#
    return email.trimmingCharacters(in: .whitespaces)
      .range(of: pattern, options: .regularExpression) != nil
  }

  var body: some View {
    NavigationView {
      ZStack {
        Color.brandBackground.ignoresSafeArea()
        if let sentTo = sentToEmail {
          successState(email: sentTo)
        } else {
          formState
        }
      }
      .navigationTitle("Reset Password")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Close") { dismiss() }
            .foregroundColor(.brandTextPrimary)
            .accessibilityIdentifier("passwordResetCloseButton")
        }
      }
    }
    .preferredColorScheme(.dark)
    .presentationDetents([.medium])
  }

  // MARK: - Form state

  @ViewBuilder
  private var formState: some View {
    VStack(spacing: 16) {
      Text("Enter your email and we'll send you a link to reset your password.")
        .font(.brandFootnote)
        .foregroundColor(.brandTextSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
        .padding(.top, 12)

      TextField("Email", text: $email)
        .textInputAutocapitalization(.never)
        .keyboardType(.emailAddress)
        .autocorrectionDisabled()
        .textContentType(.username)
        .padding()
        .background(Color.brandSurface, in: RoundedRectangle(cornerRadius: 12))
        .foregroundColor(.brandTextPrimary)
        .focused($emailFocused)
        .submitLabel(.go)
        .onSubmit { Task { await submit() } }
        .padding(.horizontal)
        .accessibilityIdentifier("passwordResetEmailField")

      if let err = errorText {
        Text(err)
          .font(.brandFootnote)
          .foregroundColor(.brandError)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)
          .accessibilityIdentifier("passwordResetErrorLabel")
      }

      Button(action: { Task { await submit() } }) {
        HStack {
          if isBusy { ProgressView().tint(.white) }
          Text(isBusy ? "Sending…" : "Reset Password")
            .bold()
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(isEmailValid ? Color.brandAccent : Color.brandStrokeStrong)
        .foregroundColor(.brandTextPrimary)
        .cornerRadius(12)
        .animation(.easeInOut(duration: 0.2), value: isEmailValid)
      }
      .disabled(!isEmailValid || isBusy)
      .padding(.horizontal)
      .accessibilityIdentifier("passwordResetSubmitButton")

      Spacer()
    }
    .task {
      // Focus the field when launched empty so the user can type immediately;
      // when pre-filled, leave focus off so the submit button is the next
      // natural tap target.
      if email.isEmpty { emailFocused = true }
    }
  }

  // MARK: - Success state

  @ViewBuilder
  private func successState(email: String) -> some View {
    VStack(spacing: 16) {
      Image(systemName: "envelope.badge")
        .font(.system(size: 64))
        .foregroundColor(.brandAccent)
        .padding(.top, 32)

      Text("Check your email")
        .font(.brandTitle3.weight(.bold))
        .foregroundColor(.brandTextPrimary)

      Text("If an account exists for \(email), we've sent a link to reset your password. Open it on this device to continue.")
        .font(.brandFootnote)
        .foregroundColor(.brandTextSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)

      Spacer()

      Button { dismiss() } label: {
        Text("Close")
          .bold()
          .frame(maxWidth: .infinity)
          .padding()
          .background(Color.brandAccent)
          .foregroundColor(.brandTextPrimary)
          .cornerRadius(12)
      }
      .padding(.horizontal)
      .padding(.bottom, 16)
      .accessibilityIdentifier("passwordResetDoneButton")
    }
    .accessibilityIdentifier("passwordResetSuccess")
  }

  // MARK: - Action

  private func submit() async {
    let trimmed = email.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    errorText = nil
    isBusy = true
    do {
      try await AuthService.shared.requestPasswordReset(email: trimmed)
      sentToEmail = trimmed
    } catch {
      errorText = error.localizedDescription
    }
    isBusy = false
  }
}
