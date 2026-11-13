import Foundation

/// Defines when persisted meal-energy evidence can distinguish an explicit
/// zero from a compatibility sentinel or unresolved value.
public enum MealEnergyAvailabilityPolicy {
    /// A zero-energy estimate is usable only when every contributing evidence
    /// item is current and resolved. Empty evidence is never proof of zero.
    public static func supportsExplicitZero(_ evidence: [EvidenceSnapshot]) -> Bool {
        guard !evidence.isEmpty else { return false }
        return evidence.allSatisfy {
            $0.grade != .legacyPointEstimate && $0.grade != .unresolved
        }
    }

    /// Evidence suitable for current daily accounting and zero-value output.
    public static func hasCurrentResolvedEvidence(_ evidence: [EvidenceSnapshot]) -> Bool {
        supportsExplicitZero(evidence)
    }
}
