# Orbit UI v1.2 implementation notes

Approved Canva prototype: <https://www.canva.com/d/HMWHySIIBED-80L>

This phase implements the iPhone-side visual foundation and the data services
required by the approved target UI. It keeps the existing five-tab information
architecture and all confirmation boundaries.

## Reused application boundaries

- `VoiceCommandRouter`, `IntelligenceRoutingPolicy`, and the existing local or
  DeepSeek paths remain the only text-routing paths.
- `PendingActionStore` remains the mandatory boundary before a meal or workout
  record is persisted.
- `DailyMetrics` remains the source for daily and rolling weekly analytics.
- HealthKit import cursors remain the source of the last successful import time.
- WorkoutKit and HealthKit behavior is unchanged in this phase.

## New implementation pieces

- `OrbitDesignSystem.swift` supplies semantic dark surfaces, named brand colors,
  reusable headers, cards, status badges, metrics, and decorative orbit geometry.
- `WeeklyAnalyticsService` builds an explicit seven-day series and upserts the
  current `WeeklyReport`; missing dates remain marked as missing.
- `CapabilityDiagnosticsService` publishes device HealthKit availability,
  runtime HealthKit entitlement presence, dietary-energy write authorization,
  authorization-request state, microphone and Speech authorization, modern
  on-device speech availability, and the last HealthKit import time.
- Onboarding, conversation, dashboard, history, workout planning, settings, and
  confirmation cards consume the shared design system while retaining native
  `NavigationStack`, `TabView`, `Form`, `List`, and `Chart` semantics.

## Platform privacy boundary

HealthKit exposes write authorization status, but it deliberately does not tell
an app whether read access was denied. The settings UI therefore labels read
authorization as system-protected instead of claiming an allowed or denied
state.

## Follow-up phase

- Connect the existing meal evidence domain to a SwiftUI photo/barcode/OCR flow.
- Transfer strength-set plan context and the next-set index to watchOS through
  WatchConnectivity, while keeping the workout state machine and HealthKit
  workout schema unchanged.
