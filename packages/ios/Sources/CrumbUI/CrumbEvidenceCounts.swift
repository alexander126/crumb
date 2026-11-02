import CrumbCore
import Foundation

/// The counts the reporter shows the user.
///
/// Every one of them has to be derived from the capture that actually
/// happened. The masking caption in particular is a privacy claim shown next to
/// the screenshot the user is about to send, so a fixed number there tells the
/// user something false about their own data.
///
/// Free of UIKit so the rules are testable on any host.
enum CrumbEvidenceCounts {
    /// Caption under a screenshot, describing what masking actually removed.
    static func maskingCaption(maskingApplied: Bool, maskedViewCount: Int) -> String {
        guard maskingApplied else {
            return crumbLocalized("Text-field masking is off")
        }
        switch maskedViewCount {
        case 0:
            // Masking was configured and ran, but this screen had nothing to hide.
            return crumbLocalized("No text fields to hide")
        case 1:
            return crumbLocalized("1 text field hidden")
        default:
            return String(
                format: crumbLocalized("%lld text fields hidden"),
                maskedViewCount
            )
        }
    }

    static func attachedItemsTitle(rowCount: Int) -> String {
        rowCount == 1
            ? crumbLocalized("What’s attached · 1 item")
            : String(format: crumbLocalized("What’s attached · %lld items"), rowCount)
    }

    static func itemsValue(_ count: Int) -> String {
        count == 1
            ? crumbLocalized("1 item")
            : String(format: crumbLocalized("%lld items"), count)
    }

    /// Evidence the report does not contain. Each entry is a thing the reporter
    /// would otherwise list, so an absent one is worth telling the user about.
    static func unavailableItemCount(
        diagnostics: CrumbDiagnosticsSnapshot,
        hasScreenshot: Bool
    ) -> Int {
        var count = 0
        if !hasScreenshot { count += 1 }
        if diagnostics.cpuUsagePercent == nil { count += 1 }
        if diagnostics.residentMemoryBytes == nil { count += 1 }
        if diagnostics.logs.status != .captured { count += 1 }
        if diagnostics.stackTraces.status != .captured { count += 1 }
        if diagnostics.network.healthCheck == nil { count += 1 }
        if diagnostics.rendering == nil { count += 1 }
        return count
    }
}
