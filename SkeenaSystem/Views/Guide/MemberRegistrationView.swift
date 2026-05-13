// Bend Fly Shop

import SwiftUI
import UIKit

struct MemberRegistrationView: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var auth = AuthService.shared
  @StateObject private var communityService = CommunityService.shared

  // MARK: - Community Code

  // MARK: - Constants

  private let supabaseSignupURL = AppEnvironment.shared.projectURL.appendingPathComponent("/auth/v1/signup")
  private let supabaseAnonKey = AppEnvironment.shared.anonKey

  // MARK: - Registration path

  /// nil = choice screen, true = invite path, false = full registration
  ///
  /// Seeded by `init()` based on the `PUBLIC_ON` build-time flag: when
  /// `PUBLIC_ON` is true the user starts on the choice screen; when it's
  /// false we skip the choice screen entirely and land on the invite path
  /// (community code + member number both mandatory) since the no-code
  /// path is disabled for that build.
  @State private var hasCommunityCode: Bool?

  /// Snapshot of the `PUBLIC_ON` entitlement captured at view construction.
  /// Drives both the initial value of `hasCommunityCode` and the back-arrow
  /// behavior — when public sign-up is off, "back" must dismiss the sheet
  /// directly rather than returning to a choice screen the user can never
  /// see.
  private let publicSignUpEnabled: Bool

  init() {
    let publicOn = readEntitlement("PUBLIC_ON")
    self.publicSignUpEnabled = publicOn
    // When public sign-up is gated off, jump straight into the invite-only
    // form so the user is asked for their community code and member number
    // up front. Otherwise leave the state at nil so the choice screen
    // renders first.
    self._hasCommunityCode = State(initialValue: publicOn ? nil : true)
  }

  // MARK: - Form fields

  @State private var communityCode: String = ""
  @State private var memberNumber: String = ""

  @State private var firstName: String = ""
  @State private var lastName: String = ""

  @State private var email: String = ""
  @State private var password: String = ""
  @State private var confirm: String = ""

  // MARK: - Hidden fields populated by scan (sent to API if available)

  enum Sex: String, CaseIterable, Identifiable { case male, female, other; var id: String { rawValue } }
  enum Residency: String, CaseIterable, Identifiable { case US, CA, other; var id: String { rawValue } }

  @State private var telephoneNumber: String = ""

  // MARK: - UI state

  @State private var isBusy = false
  @State private var errorText: String?

  // MARK: - Password requirements

  private var hasMinLength: Bool { password.count >= 8 }
  private var hasUppercase: Bool { password.range(of: "[A-Z]", options: .regularExpression) != nil }
  private var hasLowercase: Bool { password.range(of: "[a-z]", options: .regularExpression) != nil }
  private var hasNumber: Bool { password.range(of: "[0-9]", options: .regularExpression) != nil }
  private var passwordMeetsRequirements: Bool { hasMinLength && hasUppercase && hasLowercase && hasNumber }
  private var passwordsMatch: Bool { !confirm.isEmpty && password == confirm }

  // MARK: - Derived state

  private var isPasswordValid: Bool {
    passwordMeetsRequirements && passwordsMatch
  }

  private var isEmailValid: Bool {
    let pattern = #"^\S+@\S+\.\S+$"#
    return email.range(of: pattern, options: .regularExpression) != nil
  }

  private var isCommunityCodeValid: Bool {
    let code = communityCode.trimmingCharacters(in: .whitespacesAndNewlines)
    return code.range(of: #"^[A-Za-z0-9]{6}$"#, options: .regularExpression) != nil
  }

  private var isMemberNumberValid: Bool {
    MemberNumber.isValid(MemberNumber.normalize(memberNumber))
  }

  private var allFieldsFilled: Bool {
    let base = !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && isEmailValid
    // Community code is optional for full registration (Path C)
    let codeOK = communityCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCommunityCodeValid
    return base && codeOK
  }

  private var canRegister: Bool {
    !isBusy && isPasswordValid && allFieldsFilled
  }

  /// Validation for the invite-based registration path (no name/license required)
  private var canRegisterInvite: Bool {
    !isBusy && isPasswordValid && isEmailValid && isCommunityCodeValid && isMemberNumberValid
  }

  // Shared style for compact fields
  private func fieldBackground<Content: View>(_ content: Content) -> some View {
    content
      .padding(.horizontal, 10)
      .frame(height: 40) // compact height
      .background(Color.brandSurface, in: RoundedRectangle(cornerRadius: 10))
      .foregroundColor(.brandTextPrimary)
  }

  // MARK: - Body

  var body: some View {
    ZStack {
      Color.brandBackground.ignoresSafeArea()
      mainContent
    }
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button(action: {
          // When public sign-up is gated off, the choice screen is bypassed
          // entirely — there's nothing behind the invite form to go back
          // to, so "back" must always dismiss. When public sign-up is on,
          // keep the existing two-step behavior (return to choice from a
          // selected path, then dismiss from the choice screen).
          if hasCommunityCode != nil && publicSignUpEnabled {
            hasCommunityCode = nil
            resetAllFields()
          } else {
            dismiss()
          }
        }) {
          Image(systemName: "chevron.left")
            .font(.brandTitle3.weight(.semibold))
            .foregroundColor(.brandTextPrimary)
        }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("Registration")
  }

  // MARK: - Composed subviews

  @ViewBuilder
  private var mainContent: some View {
    switch hasCommunityCode {
    case nil:
      communityCodeChoiceScreen
    case true:
      inviteRegistrationContent
    case false:
      fullRegistrationContent
    }
  }

  // MARK: - Choice Screen

  @ViewBuilder
  private var communityCodeChoiceScreen: some View {
    VStack(spacing: 24) {
      Spacer()

      Image("MadThinkerLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 120, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 16))

      Text("Do you have a community code and member number?")
        .font(.brandTitle3.weight(.semibold))
        .foregroundColor(.brandTextPrimary)
        .multilineTextAlignment(.center)

      Text("These would have been shared with you by your guide or community admin.")
        .font(.brandSubheadline)
        .foregroundColor(.brandTextSecondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)

      VStack(spacing: 12) {
        Button {
          hasCommunityCode = true
        } label: {
          HStack {
            Image(systemName: "ticket")
            Text("Yes, I have both")
          }
          .font(.brandSubheadline.weight(.semibold))
          .frame(maxWidth: .infinity)
          .frame(height: 48)
          .background(Color.brandAccent, in: RoundedRectangle(cornerRadius: 12))
          .foregroundColor(.brandTextPrimary)
        }
        .accessibilityIdentifier("hasCodeButton")

        Button {
          hasCommunityCode = false
        } label: {
          HStack {
            Image(systemName: "person.badge.plus")
            Text("No, continue without one")
          }
          .font(.brandSubheadline.weight(.semibold))
          .frame(maxWidth: .infinity)
          .frame(height: 48)
          .background(Color.brandStroke, in: RoundedRectangle(cornerRadius: 12))
          .foregroundColor(.brandTextPrimary)
        }
        .accessibilityIdentifier("noCodeButton")
      }
      .padding(.horizontal, 24)

      Spacer()
      Spacer()
    }
  }

  // MARK: - Invite Registration Path

  @ViewBuilder
  private var inviteRegistrationContent: some View {
    VStack(spacing: 0) {
      ScrollView {
        Image("MadThinkerLogo")
          .resizable()
          .scaledToFit()
          .frame(width: 120, height: 120)
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .padding(.top, 12)
          .padding(.bottom, 4)

        VStack(spacing: 10) {
          inviteRegistrationForm
          errorView
        }
        .padding(.top, 8)
      }

      inviteRegisterButtonBar
    }
  }

  @ViewBuilder
  private var inviteRegistrationForm: some View {
    VStack(spacing: 10) {
      communityCodeField
      memberNumberField
      emailField
      passwordFields
    }
    .padding(.horizontal)
  }

  @ViewBuilder
  private var inviteRegisterButtonBar: some View {
    VStack(spacing: 8) {
      policyAgreementText

      Button {
        Task { await createInviteAccountTapped() }
      } label: {
        HStack {
          if isBusy { ProgressView() }
          Text(isBusy ? "Registering…" : "Register")
            .font(.brandHeadline.bold())
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(canRegisterInvite ? Color.brandAccent : Color.brandAccent.opacity(0.4))
        )
        .foregroundColor(.brandTextPrimary)
        .padding(.horizontal)
      }
      .disabled(!canRegisterInvite)
      .padding(.bottom, 10)
    }
    .padding(.top, 4)
    .background(Color.brandBackground.ignoresSafeArea(edges: .bottom))
  }

  // MARK: - Full Registration Path (existing)

  @ViewBuilder
  private var fullRegistrationContent: some View {
    VStack(spacing: 0) {
      ScrollView {
        // Platform branding — MadThinker logo (not community-specific)
        Image("MadThinkerLogo")
          .resizable()
          .scaledToFit()
          .frame(width: 120, height: 120)
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .padding(.top, 12)
          .padding(.bottom, 4)

        VStack(spacing: 10) {
          registrationForm
          errorView
        }
        .padding(.top, 8)
      }

      registerButtonBar
    }
  }

  // Whole form stack
  @ViewBuilder
  private var registrationForm: some View {
    VStack(spacing: 10) {
      nameFields
      telephoneField
      emailField
      passwordFields
    }
    .padding(.horizontal)
  }

  @ViewBuilder
  private var communityCodeField: some View {
    fieldBackground(
      TextField("Community Code", text: $communityCode)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .keyboardType(.asciiCapable)
        .accessibilityIdentifier("communityCode_registration")
    )

    if !communityCode.isEmpty {
      HStack(spacing: 4) {
        Image(systemName: isCommunityCodeValid ? "checkmark.circle.fill" : "xmark.circle.fill")
          .font(.brandCaption2)
          .foregroundColor(isCommunityCodeValid ? .green : .red)
        Text(isCommunityCodeValid ? "Valid code format" : "Must be 6 alphanumeric characters")
          .font(.brandCaption2)
          .foregroundColor(isCommunityCodeValid ? .green : .red)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
    }
  }

  @ViewBuilder
  private var memberNumberField: some View {
    fieldBackground(
      TextField("Member Number (e.g. MAD4ZQ7H9)", text: $memberNumber)
        .textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
        .keyboardType(.asciiCapable)
        .accessibilityIdentifier("memberNumber_registration")
    )

    if !memberNumber.isEmpty {
      HStack(spacing: 4) {
        Image(systemName: isMemberNumberValid ? "checkmark.circle.fill" : "xmark.circle.fill")
          .font(.brandCaption2)
          .foregroundColor(isMemberNumberValid ? .green : .red)
        Text(isMemberNumberValid ? "Valid member number" : "Enter the 9-char code from your invite email")
          .font(.brandCaption2)
          .foregroundColor(isMemberNumberValid ? .green : .red)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
    }
  }

  @ViewBuilder
  private var nameFields: some View {
    HStack(spacing: 8) {
      fieldBackground(
        TextField("First name", text: $firstName)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled()
          .submitLabel(.next)
          .accessibilityIdentifier("firstNameTextField")
      )

      fieldBackground(
        TextField("Last name", text: $lastName)
          .textInputAutocapitalization(.words)
          .autocorrectionDisabled()
          .submitLabel(.next)
          .accessibilityIdentifier("lastNameTextField")
      )
    }
  }

  // License number and license fields removed — member_id is auto-generated on backend.

  @ViewBuilder
  private var telephoneField: some View {
    fieldBackground(
      TextField("Phone Number", text: $telephoneNumber)
        .keyboardType(.phonePad)
        .textContentType(.telephoneNumber)
        .autocorrectionDisabled(true)
        .submitLabel(.next)
        .accessibilityIdentifier("phoneTextField")
    )
  }

  @ViewBuilder
  private var emailField: some View {
    fieldBackground(
      TextField("Email", text: $email)
        .textInputAutocapitalization(.never)
        .keyboardType(.emailAddress)
        .autocorrectionDisabled(true)
        .disableAutocorrection(true)
        .textContentType(.none)
        .privacySensitive()
        .submitLabel(.next)
        .accessibilityIdentifier("emailTextField_reg")
    )

    // Email validation indicator
    if !email.isEmpty {
      HStack(spacing: 4) {
        Image(systemName: isEmailValid ? "checkmark.circle.fill" : "xmark.circle.fill")
          .font(.brandCaption2)
          .foregroundColor(isEmailValid ? .green : .red)
        Text(isEmailValid ? "Valid email" : "Enter a valid email address")
          .font(.brandCaption2)
          .foregroundColor(isEmailValid ? .green : .red)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
    }
  }

  @ViewBuilder
  private var passwordFields: some View {
    fieldBackground(
      SecureField("Password", text: $password)
        .textContentType(.none)
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
        .keyboardType(.default)
        .disableAutocorrection(true)
        .submitLabel(.next)
        .accessibilityIdentifier("passwordTextField_reg")
    )

    // Password requirements — always visible
    VStack(alignment: .leading, spacing: 2) {
      Text("Password must contain:")
        .font(.brandCaption2)
        .foregroundColor(.brandTextSecondary)
      passwordRequirement("At least 8 characters", met: hasMinLength)
      passwordRequirement("One uppercase letter", met: hasUppercase)
      passwordRequirement("One lowercase letter", met: hasLowercase)
      passwordRequirement("One number", met: hasNumber)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 4)

    fieldBackground(
      SecureField("Confirm password", text: $confirm)
        .textContentType(.none)
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
        .keyboardType(.default)
        .disableAutocorrection(true)
        .privacySensitive()
        .submitLabel(.done)
        .accessibilityIdentifier("confirmPasswordTextField_reg")
    )

    // Confirm password match indicator
    if !confirm.isEmpty {
      HStack(spacing: 4) {
        Image(systemName: passwordsMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
          .font(.brandCaption2)
          .foregroundColor(passwordsMatch ? .green : .red)
        Text(passwordsMatch ? "Passwords match" : "Passwords do not match")
          .font(.brandCaption2)
          .foregroundColor(passwordsMatch ? .green : .red)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
    }
  }

  private func passwordRequirement(_ text: String, met: Bool) -> some View {
    HStack(spacing: 4) {
      Image(systemName: met ? "checkmark.circle.fill" : "circle")
        .font(.brandCaption2)
        .foregroundColor(met ? .green : .gray)
        .frame(width: 12)
      Text(text)
        .font(.brandCaption2)
        .foregroundColor(met ? .green : .gray)
    }
  }

  @ViewBuilder
  private var policyAgreementText: some View {
    VStack(spacing: 2) {
      Text("By clicking Register, you agree to our")
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
  }

  @ViewBuilder
  private var errorView: some View {
    if let err = errorText {
      Text(err)
        .foregroundColor(.brandError)
        .font(.brandFootnote)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }
  }

  @ViewBuilder
  private var registerButtonBar: some View {
    VStack(spacing: 8) {
      policyAgreementText

      Button {
        Task { await createAccountTapped() }
      } label: {
        HStack {
          if isBusy { ProgressView() }
          Text(isBusy ? "Registering…" : "Register")
            .font(.brandHeadline.bold())
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(canRegister ? Color.brandAccent : Color.brandAccent.opacity(0.4))
        )
        .foregroundColor(.brandTextPrimary)
        .padding(.horizontal)
      }
      .disabled(!canRegister)
      .accessibilityIdentifier("registerButton")
      .padding(.bottom, 10)
    }
    .padding(.top, 4)
    .background(Color.brandBackground.ignoresSafeArea(edges: .bottom))
  }

  // MARK: - Actions

  /// Invite-based registration (Path A): only community code, email, password
  private func createInviteAccountTapped() async {
    guard !email.isEmpty, !password.isEmpty else {
      errorText = "Please enter email and password."
      return
    }
    guard password == confirm else {
      errorText = "Passwords don't match."
      return
    }
    guard isCommunityCodeValid else {
      errorText = "Please enter a valid 6-character community code."
      return
    }
    guard isMemberNumberValid else {
      errorText = "Please enter the member number from your invite email (e.g. MAD4ZQ7H9)."
      return
    }

    let code = communityCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let memNum = MemberNumber.normalize(memberNumber)

    errorText = nil
    isBusy = true
    do {
      try await auth.signUpWithInvite(
        email: email.trimmingCharacters(in: .whitespaces),
        password: password,
        communityCode: code,
        memberNumber: memNum
      )
      dismiss()
    } catch {
      errorText = error.localizedDescription
    }
    isBusy = false
  }

  /// Full registration (Path B): all fields required
  private func createAccountTapped() async {
    guard !email.isEmpty, !password.isEmpty else {
      errorText = "Please enter email and password."
      return
    }
    guard password == confirm else {
      errorText = "Passwords don't match."
      return
    }

    let code = communityCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

    guard !firstName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      errorText = "Please enter your first name."
      return
    }
    guard !lastName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      errorText = "Please enter your last name."
      return
    }
    // Community code is optional for Path C; validate only if provided
    if !code.isEmpty {
      guard isCommunityCodeValid else {
        errorText = "Please enter a valid 6-character community code."
        return
      }
    }

    errorText = nil
    isBusy = true

    // Public-community registration — member_id auto-generated on backend
    do {
      try await supabaseSignUp(
        email: email.trimmingCharacters(in: .whitespaces),
        password: password,
        firstName: firstName,
        lastName: lastName,
        communityCode: code.isEmpty ? nil : code,
        dob: nil,
        sex: nil,
        mailingAddress: nil,
        telephone: telephoneNumber.trimmingCharacters(in: .whitespaces).isEmpty ? nil : telephoneNumber.trimmingCharacters(in: .whitespaces),
        residency: nil
      )
      try await auth.signIn(
        email: email.trimmingCharacters(in: .whitespaces),
        password: password
      )
      AppLogging.log("[MemberRegistration] signIn complete — isAuthenticated=\(auth.isAuthenticated)", level: .info, category: .auth)

      // Fetch memberships so AppRootView has the role + active community
      // before it picks a landing view.
      await communityService.fetchMemberships()
      AppLogging.log("[MemberRegistration] fetchMemberships complete — activeCommunityId=\(communityService.activeCommunityId ?? "nil") typeName=\(communityService.activeCommunityTypeName ?? "nil") memberships=\(communityService.memberships.count)", level: .info, category: .auth)

      dismiss()
    } catch {
      errorText = error.localizedDescription
    }
    isBusy = false
  }

  // MARK: - Supabase Signup

  private func supabaseSignUp(
    email: String,
    password: String,
    firstName: String,
    lastName: String,
    communityCode: String?,
    dob: Date?,
    sex: Sex?,
    mailingAddress: String?,
    telephone: String?,
    residency: Residency?
  ) async throws {
    var request = URLRequest(url: supabaseSignupURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")

    var dataPayload: [String: Any] = [
      "first_name": firstName,
      "last_name": lastName,
      "user_type": "public"
    ]
    if let code = communityCode, !code.isEmpty { dataPayload["community_code"] = code }

    if let d = dob { dataPayload["date_of_birth"] = DateFormatting.ymd.string(from: d) }
    if let s = sex { dataPayload["sex"] = s.rawValue }
    if let addr = mailingAddress, !addr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      dataPayload["mailing_address"] = addr
    }
    if let tel = telephone, !tel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      dataPayload["telephone_number"] = tel
    }
    if let res = residency { dataPayload["residency"] = res.rawValue }

    let body: [String: Any] = ["email": email, "password": password, "data": dataPayload]
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw NSError(domain: "Signup", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response from server."])
    }
    guard (200 ... 299).contains(http.statusCode) else {
      if let msg = parseErrorMessage(from: data), !msg.isEmpty {
        throw NSError(domain: "Signup", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
      }
      throw NSError(
        domain: "Signup",
        code: http.statusCode,
        userInfo: [NSLocalizedDescriptionKey: "Signup failed with status \(http.statusCode)."]
      )
    }
  }

  private func parseErrorMessage(from data: Data) -> String? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let msg = obj["msg"] as? String { return msg }
    if let error = obj["error_description"] as? String { return error }
    if let err = obj["error"] as? String { return err }
    if let m = obj["message"] as? String { return m }
    return nil
  }


  // MARK: - Reset helpers

  private func resetAllFields() {
    firstName = ""
    lastName = ""
    email = ""
    password = ""
    confirm = ""

    errorText = nil

    communityCode = ""
    memberNumber = ""
  }
}
