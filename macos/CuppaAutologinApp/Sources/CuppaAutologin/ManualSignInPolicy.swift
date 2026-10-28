import Foundation

/// When automatic sign-in has genuinely given up and the user must complete the
/// portal themselves. Kept dependency-free so the give-up boundary — the line
/// between "keep waiting" and "sign in yourself" — is unit-testable without a
/// full StatusModel.
enum ManualSignInPolicy {
    /// After this many consecutive failures we stop implying "just wait a bit
    /// longer". The engine's fast-retry increments the count once per in-process
    /// attempt (~4-5 within one 30s cycle), so 4 means "it has really tried".
    static let failureThreshold = 4

    /// A fail-closed portal (UNSUPPORTED: OTP/CAPTCHA/voucher/real detail) needs
    /// manual sign-in immediately — no waiting will help. An ordinary CAPTIVE
    /// portal only after it has tried and kept failing. Never while an attempt
    /// is in flight, and never when online.
    static func required(
        lastResult: String,
        consecutiveFailures: Int,
        hasActiveOperation: Bool
    ) -> Bool {
        guard !hasActiveOperation else { return false }
        if lastResult == "UNSUPPORTED" { return true }
        return lastResult == "CAPTIVE"
            && consecutiveFailures >= failureThreshold
    }
}
