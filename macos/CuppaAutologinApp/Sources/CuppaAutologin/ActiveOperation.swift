import Foundation

enum ActiveOperation: Equatable {
    case starting
    case checkingConnection
    case handlingPortal
    case verifyingAccess
    case updatingMonitoring

    var title: String {
        switch self {
        case .starting:
            "Starting"
        case .checkingConnection:
            "Checking Wi-Fi"
        case .handlingPortal:
            "Signing in"
        case .verifyingAccess:
            "Verifying access"
        case .updatingMonitoring:
            "Updating monitoring"
        }
    }

    var progressText: String {
        switch self {
        case .starting:
            "Preparing the sign-in engine…"
        case .checkingConnection:
            "Checking the connection and looking for a portal…"
        case .handlingPortal:
            "Reading fields, filling the form and submitting it…"
        case .verifyingAccess:
            "Form submitted — checking that internet access returned…"
        case .updatingMonitoring:
            "Applying the automatic monitoring change…"
        }
    }

    var disabledReason: String {
        switch self {
        case .starting:
            "Check Now is unavailable while the sign-in engine starts."
        case .checkingConnection:
            "Check Now is unavailable because a connection check is already running."
        case .handlingPortal:
            "Check Now is unavailable while the portal form is being filled and submitted."
        case .verifyingAccess:
            "Check Now is unavailable while internet access is being verified."
        case .updatingMonitoring:
            "Check Now is unavailable while automatic monitoring is being updated."
        }
    }
}

struct CheckNowAvailability {
    let isBusy: Bool
    let webViewIsActive: Bool
    let monitoringIsActive: Bool
    let lastResult: String
    let consecutiveFailures: Int
    let portalAttemptNeedsRetry: Bool
    let activeOperation: ActiveOperation?

    private var automaticPortalIsActive: Bool {
        monitoringIsActive
            && lastResult == "CAPTIVE"
            && consecutiveFailures == 0
            && !portalAttemptNeedsRetry
    }

    var isDisabled: Bool {
        isBusy || webViewIsActive || automaticPortalIsActive
    }

    var disabledReason: String? {
        if let activeOperation {
            return activeOperation.disabledReason
        }
        if webViewIsActive || automaticPortalIsActive {
            return "Check Now is unavailable because automatic sign-in is already handling this portal."
        }
        if isBusy {
            return "Check Now is unavailable while the app finishes its current task."
        }
        return nil
    }
}
