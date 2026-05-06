//
//  MemberNumber.swift
//  SkeenaSystem
//
//  Input normalization for Mad Thinker member numbers (Crockford Base32).
//  Format: "MAD" prefix + 6 Crockford Base32 characters = 9 chars total.
//  Permitted chars in the unique code: 0-9 A-H J K M N P-T V-Z (no I, L, O, U).
//

import Foundation

nonisolated enum MemberNumber {

    // MARK: - Crockford Base32 normalization

    /// Normalizes a member number input per Crockford Base32 rules:
    /// 1. Uppercase
    /// 2. Strip spaces, hyphens, and other separators
    /// 3. Crockford error correction (I/i→1, L/l→1, O/o→0)
    static func normalize(_ input: String) -> String {
        var result = input
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")

        // Crockford error corrections
        result = result
            .replacingOccurrences(of: "I", with: "1")
            .replacingOccurrences(of: "L", with: "1")
            .replacingOccurrences(of: "O", with: "0")

        return result
    }

    /// Validates that a normalized member number matches the expected format:
    /// "MAD" prefix followed by exactly 6 Crockford Base32 characters.
    static func isValid(_ input: String) -> Bool {
        let normalized = normalize(input)
        guard normalized.count == 9,
              normalized.hasPrefix("MAD") else { return false }
        let code = normalized.dropFirst(3)
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return code.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
