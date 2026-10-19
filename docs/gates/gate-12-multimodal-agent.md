# Gate 12 — Multimodal Agent

Status: focused CI gate over the text, voice and image routes through one
AgentSession.

## Current implementation boundary

Text and voice-transcribed text are sent through `AgentSession`. Photo meal
capture sanitizes and scans on device first. A matched barcode or usable local
nutrition label takes a local review path and creates only a `PendingAction`;
the photo is not included in a model request. If the consumed portion is not
known, the user answers one local question in grams or a count convertible from
a known package serving mass. No meal record is saved before confirmation.

Open-photo requests pass a bounded `MultimodalModelRequest` to that same
`AgentSession`. The selected provider must support vision and the user must
separately consent to DeepSeek meal-image upload. The image stays in memory and
is removed from persisted conversation history. For evidence-only requests,
bounded local scanner evidence is added as an explicitly untrusted ephemeral provider message for the current round and is passed transiently to `log_meal`;
neither the evidence message nor its OCR text is persisted. Evidence-only turns
require the regular health-text consent and do not require meal-image consent.
Confirmation remains required before any meal record is saved.
Text that the user dictated or edited before opening the photo picker is kept
as supplemental text in the same user turn as the sanitized image. It is sent
once to the same AgentSession; if no text was supplied, the photo request keeps
its default prompt.

Each turn also carries a Codable `InputEnvelope` with a request ID, local
timestamp, coarse source, user text, locale and bounded image attachment
metadata. The envelope stores no image bytes, filenames, temporary paths or
audio. Conversation storage keeps this safe envelope with the user text; the
provider request omits local envelope metadata and receives image bytes only
through the transient multimodal input. Speech and photo use `voiceAndImage`;
manually edited text and photo use `textAndImage`.

For images, DeepSeek must be the explicitly selected provider; a text-only or
Qwen provider is rejected without fallback.
Interrupted requests that depended on transient input fail closed. An image
request needs the image reattached; evidence-only input must be rescanned under
a new request ID because OCR and candidate text are not persisted.

## Focused tests

- DensosoDomain: `InputEnvelopeTests.testVoiceTextImageAndCombinedEnvelopeRoundTripOnlySafeMetadata`,
  `InputEnvelopeTests.testEnvelopeRejectsSourceAndPayloadMismatches`, and
  `InputEnvelopeTests.testVoiceCommandOriginMapsToCoarseEnvelopeSourceWithoutLosingLocale`.
- `MultimodalAgentImageTests.testImageInputUsesAgentSessionAndStagesMealWithoutDirectCommitOrRawMediaPersistence`
- `MultimodalAgentImageTests.testInterruptedImageRequestFailsClosedUntilImageIsReattachedAndKeepsBudget`
- `MultimodalAgentImageTests.testImageRequiresVisionCapabilityAndSeparateMealImageConsent`
- `MultimodalAgentImageTests.testEvidenceOnlyRequestUsesEphemeralProviderMessageWithoutImageConsentOrPersistence`
- `MultimodalAgentImageTests.testInterruptedEvidenceOnlyRequestRequiresNewRequestToReprovideEvidence`
- `MultimodalAgentImageTests.testEvidenceOnlyRequestBoundsTransientEvidence`
- `AgentCoordinatorTests.testRealRoundAndToolCountsAndPendingAction`
- `AgentCoordinatorTests.testVoiceInputEnvelopePersistsOnlySafeMetadataAndIsOmittedFromProviderMessages`
- `AgentCoordinatorTests.testProviderReasoningContinuesInMemoryButIsNeverPersisted`
- `AgentCoordinatorTests.testCloudProviderRequiresExplicitConsent`
- `AgentCoordinatorTests.testNinthToolCallStopsRequest`
- `AgentRequestResumeTests.testInterruptedRequestResumesWithPersistedRemainingBudgetAndUsage`
- `DeepSeekProviderContractTests.testResponsesAPIRequestAndStreamingToolContract`
- `DeepSeekProviderContractTests.testImageStructuredOutputAndStatelessToolHistoryEncoding`
- `QwenASRProviderContractTests.testOpenAICompatibleAudioRequestAndResponseContract`
- `QwenMealVisionProviderContractTests.testPinnedQwen37SnapshotUsesImageAndStructuredObservationContract`
- `SpeechCaptureStateMachineTests.testLocalFailureWithCapturedAudioUsesQwenOnceAndDeletesTemporaryAudio`
- `MealCaptureApplicationServiceTests.testPrepareForAgentRoutesResolvedBarcodeLocallyAndStagesPendingAction`
- `MealCaptureApplicationServiceTests.testPrepareForAgentKeepsCompleteLabelLocalAndAsksOnceForMissingPortion`
- `MealCaptureApplicationServiceTests.testPrepareForAgentUsesTextFallbackForBarcodeMissAndImageOnlyForOpenPhoto`
- `MealCaptureApplicationServiceTests.testLocalMealPortionAnswerSupportsCountsAndRejectsPackageSpecsAsConsumedAmount`
- `MealCaptureApplicationServiceTests.testOpenPhotoRequiresSeparateImageConsent`
- `MealCaptureApplicationServiceTests.testLowConfidenceVisionCannotStageFoodIDWithoutUserSelection`

The selected tests reuse existing provider fixtures and confirmation tests; no
live provider request or photo data is used.
