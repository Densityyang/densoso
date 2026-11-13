import DensosoDomain

enum ChatComposerDraftPolicy {
    static func canClearAfterRequest(
        currentText: String,
        currentSource: VoiceCommandEnvelope.Source,
        submittedText: String,
        submittedSource: VoiceCommandEnvelope.Source,
        requestSucceeded: Bool,
        retainForReview: Bool
    ) -> Bool {
        requestSucceeded
            && !retainForReview
            && currentText == submittedText
            && currentSource.rawValue == submittedSource.rawValue
    }
}
