//
//  JoinCommunityView.swift
//  SkeenaSystem
//
//  Allows authenticated users to join an additional community
//  by entering a 6–8 character alphanumeric code.
//  Presented as a compact centered popup over a dimmed background.
//

import SwiftUI

struct JoinCommunityView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var code: String = ""
    @State private var memberNumber: String = ""
    @State private var isBusy = false
    @State private var errorText: String?
    @State private var successText: String?

    private var isCodeValid: Bool {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^[A-Za-z0-9]{6,8}$"#, options: .regularExpression) != nil
    }

    private var isMemberNumberValid: Bool {
        MemberNumber.isValid(MemberNumber.normalize(memberNumber))
    }

    private var canJoin: Bool {
        isCodeValid && isMemberNumberValid && !isBusy
    }

    var body: some View {
        ZStack {
            // Dimmed backdrop — tap to dismiss
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Compact card
            VStack(spacing: 14) {
                // Title + close
                ZStack {
                    Text("Join Community")
                        .font(.headline)
                        .foregroundColor(.white)
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }

                // Community code
                TextField("Community Code", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(.white)

                if !code.isEmpty && !isCodeValid {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                        Text("Must be 6–8 alphanumeric characters")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Member number (from invite email)
                TextField("Member Number (e.g. MAD4ZQ7H9)", text: $memberNumber)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(.white)

                if !memberNumber.isEmpty && !isMemberNumberValid {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                        Text("Enter the 9-char code from your invite email")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Join button
                Button {
                    Task { await joinTapped() }
                } label: {
                    HStack(spacing: 6) {
                        if isBusy { ProgressView().tint(.white) }
                        Text(isBusy ? "Joining…" : "Join")
                            .font(.subheadline.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(canJoin ? Color.blue : Color.blue.opacity(0.35))
                    )
                    .foregroundColor(.white)
                }
                .disabled(!canJoin)

                if let err = errorText {
                    Text(err)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }

                if let success = successText {
                    Text(success)
                        .foregroundColor(.green)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(white: 0.12))
            )
            .padding(.horizontal, 32)
        }
        .presentationBackground(.clear)
        .preferredColorScheme(.dark)
    }

    private func joinTapped() async {
        errorText = nil
        successText = nil
        isBusy = true

        do {
            let result = try await CommunityService.shared.joinCommunity(
                code: code,
                memberNumber: memberNumber
            )
            successText = "Joined \(result.communityName ?? "community") as \(result.role ?? "member")!"
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }

        isBusy = false
    }
}
