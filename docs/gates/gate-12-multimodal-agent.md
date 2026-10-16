# Gate 12 — Multimodal Agent

Status: focused CI gate over the text, voice and image routes through one
AgentSession.

## Current implementation boundary

Text and voice-transcribed text are sent through `AgentSession`. Photo meal
capture uses `MealCaptureApplicationService` only to sanitize the image and
extract local evidence, then passes a bounded `MultimodalModelRequest` to that
same `AgentSession`. The selected provider must support vision and the user
must separately consent to DeepSeek meal-image upload. The image stays in
memory and is removed from persisted conversation history; local evidence
metadata may accompany a `log_meal` pending action, but OCR/evidence text is
not persisted. Confirmation remains required before any meal record is saved.
Text that the user dictated or edited before opening the photo picker is kept
as supplemental text in the same user turn as the sanitized image. It is sent
once to the same AgentSession; if no text was supplied, the photo request keeps
its default prompt.

For images, DeepSeek must be the explicitly selected provider; a text-only or
Qwen provider is rejected without fallback.

## Focused tests

- `MultimodalAgentImageTests.testImageInputUsesAgentSessionAndStagesMealWithoutDirectCommitOrRawMediaPersistence`
- `MultimodalAgentImageTests.testInterruptedImageRequestFailsClosedUntilImageIsReattachedAndKeepsBudget`
- `MultimodalAgentImageTests.testImageRequiresVisionCapabilityAndSeparateMealImageConsent`
- `AgentCoordinatorTests.testRealRoundAndToolCountsAndPendingAction`
- `AgentCoordinatorTests.testProviderReasoningContinuesInMemoryButIsNeverPersisted`
- `AgentCoordinatorTests.testCloudProviderRequiresExplicitConsent`
- `AgentCoordinatorTests.testNinthToolCallStopsRequest`
- `AgentRequestResumeTests.testInterruptedRequestResumesWithPersistedRemainingBudgetAndUsage`
- `DeepSeekProviderContractTests.testResponsesAPIRequestAndStreamingToolContract`
- `DeepSeekProviderContractTests.testImageStructuredOutputAndStatelessToolHistoryEncoding`
- `QwenASRProviderContractTests.testOpenAICompatibleAudioRequestAndResponseContract`
- `QwenMealVisionProviderContractTests.testImageRequestAndRestrictedObservationContract`
- `SpeechCaptureStateMachineTests.testLocalFailureWithCapturedAudioUsesQwenOnceAndDeletesTemporaryAudio`
- `MealCaptureApplicationServiceTests.testOpenPhotoRequiresSeparateImageConsent`
- `MealCaptureApplicationServiceTests.testLowConfidenceVisionCannotStageFoodIDWithoutUserSelection`

The selected tests reuse existing provider fixtures and confirmation tests; no
live provider request or photo data is used.
