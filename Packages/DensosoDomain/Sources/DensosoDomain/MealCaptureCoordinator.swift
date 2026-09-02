import Foundation

public struct MultimodalMealDraft: Codable, Equatable, Sendable {
    public enum ConfirmationState: String, Codable, Sendable {
        case requiresUserConfirmation
    }

    public let evidence: [MealEvidence]
    public let portion: PortionEstimate?
    public let cookingMethod: String?
    public let nextClarification: MealClarification?
    public let confirmationState: ConfirmationState

    public init(
        evidence: [MealEvidence],
        portion: PortionEstimate?,
        cookingMethod: String?,
        nextClarification: MealClarification?,
        confirmationState: ConfirmationState = .requiresUserConfirmation
    ) {
        self.evidence = evidence
        self.portion = portion
        self.cookingMethod = cookingMethod
        self.nextClarification = nextClarification
        self.confirmationState = confirmationState
    }
}

/// Pure coordinator for local photo, barcode, OCR, and voice evidence. It has
/// no persistence, network, image, agent, or HealthKit dependency by design.
public struct MealCaptureCoordinator: Sendable {
    private let clarificationSelector: ClarificationSelector

    public init(clarificationSelector: ClarificationSelector = .init()) {
        self.clarificationSelector = clarificationSelector
    }

    public func makeDraft(
        evidence: [MealEvidence],
        portion: PortionEstimate? = nil,
        cookingMethod: String? = nil
    ) -> MultimodalMealDraft {
        MultimodalMealDraft(
            evidence: evidence,
            portion: portion,
            cookingMethod: cookingMethod,
            nextClarification: clarificationSelector.nextQuestion(
                candidates: evidence,
                portion: portion,
                cookingMethod: cookingMethod
            )
        )
    }
}
