# Gate 12 — Multimodal Agent

Status: focused CI gate over the text, voice and image routes through one
AgentSession.

Performance points of interest mark `App.LaunchStart`,
`Today.InitialContentRendered`, `Today.InitialDataReady`, `Health.StateRefresh`,
`Meal.DeterministicEstimate`, `Meal.DeterministicToolDraft`,
`Speech.CaptureToFirstTranscript`, `Provider.DeepSeekFirstTextDelta`,
`Agent.TranscriptToFirstToken`, and `Agent.TranscriptToActionDraft`. The local
food catalog is cached as an immutable in-process snapshot so Agent meal turns
do not re-read and remap the full SQLite catalog on every request. These spans
make the PR targets inspectable in Instruments; they do not claim those targets
have been met on user hardware.

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
DeepSeek is the default photo route. Qwen Vision is a separate optional mode;
it is not selected as a fallback, and its open-photo UI remains unavailable
while its quality gate is closed. Cloud Qwen shows an explicit unsupported
message and asks for a deliberate settings change before a DeepSeek request.
Vision capability is scoped to the exact `deepseek-flash` model and the official
`https://api.deepseek.com/responses` endpoint. Its Responses API payload uses
`input_image` parts as specified in
the [DeepSeek Vision guide](https://api-docs.deepseek.com/guides/vision/) and
[Responses API guide](https://api-docs.deepseek.com/guides/responses_api/).
Image parts are allowed only in user messages; provider validation rejects any
other image role before sending a request.
DeepSeek's current V4.1 Flash API model has native visual understanding and is
called by its canonical API name, `deepseek-flash`; the retired
`deepseek-v4-flash-vision-exp` name is only a compatibility alias routed to the
current Flash model. The app therefore sends images to `deepseek-flash` through
the Responses API instead of requiring a separate vision model or silently
switching to Qwen.
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

Agent, Narrative, Meal, and Vision prompt builders expose centralized version
identifiers. New conversations persist `toolSchemaVersion=2`; conversations
migrated from V1–V6 are lazily marked as schema v1, and their stored message
history remains readable before new turns use the current v2 tool definitions.

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
- `AgentCoordinatorTests.testTypedEventStreamPreservesOrderAndRealCounts`
- `AgentCoordinatorTests.testProviderReasoningContinuesInMemoryButIsNeverPersisted`
- `AgentCoordinatorTests.testCloudProviderRequiresExplicitConsent`
- `AgentCoordinatorTests.testNinthToolCallStopsRequest`
- `AgentRequestResumeTests.testInterruptedRequestResumesWithPersistedRemainingBudgetAndUsage`
- `AgentRequestResumeTests.testLegacyV1ConversationRestoresWithCurrentToolsAndAdvancesOnNewTurn`
- `DensosoMigrationTests.testV6ToV7PreservesLegacyConversationAndRestoresToolSchemaV1`
- `DensosoMigrationTests.testV1DiskFixtureMigratesToCurrentSchemaWithoutRecalculation`
- `DensosoMigrationTests.testV2DiskFixtureMigratesToCurrentSchemaAndPreservesCursorAndOutbox`
- `DensosoMigrationTests.testV3MigrationToCurrentSchemaCreatesTimeAwareProfileAndWeightRecords`
- `DensosoMigrationTests.testPersistenceBootstrapErrorsUseSafeReadOnlyDescriptor`
- `ConfirmationCoordinatorTests.testConfirmedActionTraceabilityLinksReceiptLocalRecordAndOutbox`
- `PromptVersioningTests.testPromptAndToolSchemaVersionsMatchMainPR111And112`
- `DeepSeekProviderContractTests.testResponsesAPIRequestAndStreamingToolContract`
- `DeepSeekProviderContractTests.testImageStructuredOutputAndStatelessToolHistoryEncoding`
- `DeepSeekProviderContractTests.testImageMustBeInUserMessageAndFailsBeforeNetwork`
- `QwenASRProviderContractTests.testOpenAICompatibleAudioRequestAndResponseContract`
- `QwenMealVisionProviderContractTests.testPinnedQwen37SnapshotUsesImageAndStructuredObservationContract`
- `DiagnosticsExportPrivacyTests.testProviderErrorsExportOnlyAllowlistedCodes`
- `SpeechCaptureStateMachineTests.testLocalFailureWithCapturedAudioUsesQwenOnceAndDeletesTemporaryAudio`
- `MealCaptureApplicationServiceTests.testPrepareForAgentRoutesResolvedBarcodeLocallyAndStagesPendingAction`
- `MealCaptureApplicationServiceTests.testPrepareForAgentKeepsCompleteLabelLocalAndAsksOnceForMissingPortion`
- `MealCaptureApplicationServiceTests.testPrepareForAgentUsesTextFallbackForBarcodeMissAndImageOnlyForOpenPhoto`
- `MealCaptureApplicationServiceTests.testLocalMealPortionAnswerSupportsCountsAndRejectsPackageSpecsAsConsumedAmount`
- `MealCaptureApplicationServiceTests.testOptionalQwenOpenPhotoRequiresSeparateQwenConsent`
- `MealCaptureApplicationServiceTests.testDeepSeekPhotoModeNeverFallsThroughToOptionalQwenVision`
- `MealCaptureApplicationServiceTests.testDefaultClosedQualityGateRequiresManualFallbackWithoutStaging`
- `FoodDatabaseTests.testCatalogEntriesRemainStableAcrossRepeatedReads`
- `AppLaunchConfigurationTests.testSeededProfileRequiresUITestMode`
- `AppLaunchConfigurationTests.testUITestArgumentsEnableDeterministicSeed`
- `MealCaptureApplicationServiceTests.testMealCaptureErrorsExposeSharedSafeDescriptors`
- `MealRecordAuditPresentationTests.testMealRecordPresentationShowsSanitizedSourcesAndAlgorithmVersion`
- `AgentUIStateMachineTests.testAgentEventsMoveThroughThinkingToolDraftConfirmationCommitAndFailureStates`
- `AgentUIStateMachineTests.testVoiceUIStateMapsExistingSpeechCaptureStatesAndFailureKinds`
- `MealImageCaptureStateMachineTests.testOpenPhotoRequiresConsentBeforeUploadAndMovesThroughVisionResolution`
- `MealImageCaptureStateMachineTests.testLocalResolutionAndCancellationNeverBecomeUploadable`
- `IntelligenceRoutingPolicyTests.testDefaultModeIsCloudDeepSeek`
- `IntelligenceRoutingPolicyTests.testDeepSeekVisionCapabilityIsScopedToDocumentedModelAndEndpoint`
- `IntelligenceRoutingPolicyTests.testCloudRequiresExplicitCloudMode`
- `MealCaptureApplicationServiceTests.testLocalOnlyBarcodeScanNeverCallsPackagedFoodProvider`
- `SpeechCaptureStateMachineTests.testLocalOnlyModeNeverUsesQwenFallbackEvenWhenFallbackAndConsentAreEnabled`
- `MealCaptureApplicationServiceTests.testLowConfidenceVisionCannotStageFoodIDWithoutUserSelection`

The selected tests reuse existing provider fixtures and confirmation tests; no
live provider request or photo data is used.

Photo capture reports local selection, sanitizing, scanning and resolution
states separately from DeepSeek requirement, saved photo consent, upload, vision
and completion. A sanitized request remains local until its explicit DeepSeek
meal-image consent is saved and the user presses send; AgentSession checks the
same consent again before the upload event. Image state events carry no image or
OCR content, and cancellation clears pending photo data.

Cloud DeepSeek is the default mode, and selected cloud providers are constructed
directly without silent fallback to another provider. Local Only keeps model,
speech and meal-image work on device: it suppresses OpenFoodFacts barcode lookup,
Qwen ASR fallback and Qwen Vision; when local capabilities are unavailable, the
user gets manual entry instead of an automatic network request.
Production launch does not seed a profile; deterministic profile fixtures are
available only in UI-test mode. Qwen open-photo quality remains closed by
default, so a synthetic fixture cannot enable a production vision route.

Confirmed meal history displays sanitized source categories and the persisted
meal algorithm version. It does not display raw OCR evidence or private evidence
summaries.
