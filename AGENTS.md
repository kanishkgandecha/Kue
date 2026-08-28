# AGENTS.md — Kue

Instructions for any AI coding agent (or human) working in this repository.

## Authoritative specification

**`/Users/kanishkgandecha/Projects/Kue/docs/` is the source of truth for what Kue is and
how V1 is built.** It lives outside this repo on purpose (planning documents, not app
bundle contents) — start at `docs/README.md`, which indexes the rest.

Before editing anything in this repo:

1. Read the doc(s) that cover the subsystem you're touching (e.g. `03-data-model.md` for
   any `@Model` change, `07-widget-engine.md` for widget code, `12-roadmap-and-milestones.md`
   for what phase you're in and its exit criteria).
2. If the code and the docs disagree, the docs win — fix the code, or if the docs
   themselves are wrong, fix the docs *first*, in that repo, then implement.
3. If you hit a real gap the docs don't cover, add it to `docs/14-open-questions.md`
   rather than silently deciding and moving on.

Do not treat this repo's existing code as more authoritative than the docs just because
it compiles — Phase 1 code in particular is a foundation, not a finished design.

## The one rule that must never break

> AI interprets. The scheduling engine decides. SwiftData stores. WidgetKit surfaces.
> Notifications interrupt. Context adjusts priority.

Concretely: AI-derived output is never written directly into `KueEvent`/`KueTask`/
`KueSchedule` state — it always passes through validation/normalization and a user
confirmation step first (`docs/02-architecture.md`, `docs/06-ai-layer.md`). The scheduling
engine is deterministic — given the same event and rule set, it always produces the same
tasks; no model call in that path.

## V1 boundaries (do not build these without updating the docs first)

- **Event types:** `Generic`, `Deadline`, `Exam`, `Interview`, `Trip` only. No custom
  event-type templates.
- **Input paths:** manual entry, natural-language text, Share Sheet (text/URL). No voice,
  no OCR/screenshot import.
- **AI:** on-device only (Apple's Foundation Models framework). No cloud API calls, no
  embedded provider credentials — see `docs/06-ai-layer.md` "Parser runtime & credentials"
  for why.
- **Out of scope for all of V1:** user accounts, a backend/cloud database, social
  features, subscriptions, third-party analytics, a Mac app, calendar integration, a
  context engine (location/weather/Focus), Live Activities, Lock Screen widgets, large
  widgets. See `docs/01-vision-and-scope.md` "What NOT to build in V1" for the full list.
- **Widget size is never app-owned.** Widget family (small/medium) is chosen by the user
  per placed Home Screen instance — don't reintroduce a `size` field on
  `WidgetConfiguration` or `UserPreference`. See `docs/03-data-model.md` "WidgetConfiguration."
- **Phases build in order.** V1 (Phases 1–10 / M0–M9) is complete — see "Current
  implementation status" below. **Kue 2.0 has started** (see "Kue 2.0 has started" below):
  migration foundation, search/filter/sort/duplication, recurring events, Apple Calendar
  integration, screenshot/OCR input, and on-device voice input are all done. No other Kue 2.0
  user-facing feature (`docs/01-vision-and-scope.md` "What NOT to build in V1": a context
  engine, Live Activities, large/Lock Screen widgets, user-defined templates, ...) has been
  built, and none should be until the project owner explicitly says a specific one has started.

## Current implementation status

**Implementation is done for all ten phases / M0–M9 and the automated suite is green, but
V1 is not yet signed off** — two of Phase 4's and Phase 10's own exit criteria are manual,
device/simulator-driven checks that no amount of `xcodebuild test` satisfies, and neither has
actually been run yet:

1. **Share the same content from Safari, Mail, and Messages into Kue**, on the real Share
   Sheet (not simulated), and confirm: create, cancel, duplicate-detected, ambiguity, offline
   (airplane mode / a URL that won't resolve), AI-disabled (Settings toggle off), and
   unsupported-content (e.g. sharing a photo) all behave as documented. `KueTests` covers the
   logic each of these paths runs (`ShareContentTests`, `NLParsingPipelineTests`,
   `URLContentFetcherTests`, ...) but cannot drive the actual extension UI — see the KueTests/
   entry above for exactly why (no launchable icon for `XCUIApplication`).
2. **Place a small and a medium widget** through the Home Screen's own widget-placement flow,
   confirm both render and pick up a change made in the app (shared-store consistency), and
   exercise `CompleteTaskIntent`/`SnoozeTaskIntent`/`CompleteEventIntent` **with the app force-
   quit**, confirming the widget/notification state updates without the app ever launching.
   This has been true since Phase 4 (`docs/07-widget-engine.md` "Widget instances vs. event
   eligibility": placement "cannot be automated") and was never actually exercised in any
   phase's own report — automated tests cover the underlying logic, not the placement/
   terminated-app path itself.

Both are real Phase 1–10 exit criteria, not polish — don't report V1 as done until they've
actually been run and their result recorded here. Until then, treat the *implementation* as
established behavior (don't rewrite or refactor it without a narrowly scoped reason or a
demonstrated defect), but don't tell the project owner V1 shipped.

Genuine gaps the Phase 10 audit found and fixed (all pre-existing, not introduced by Share
Extension work itself): Settings never exposed `UserPreference.aiParsingEnabled` (declared
since Phase 1, never wired to a toggle or read by the NL entry point) or a "delete
everything" action (`docs/11-privacy-and-offline.md` — required, not optional); Event
Detail's Notifications tab still said "Reminders arrive in Phase 8" after Phase 8 shipped;
`WidgetConfiguration.showLocation` was persisted from a real UI toggle but never actually
read by `WidgetContentService.displayContent`, so turning it off had no effect; `URLContent
Fetching`'s fetch had no scheme check, response-size cap, or timeout, so a shared link to a
large/slow/non-http(s) resource could jetsam the Share Extension under its tighter memory
limit before ever returning — fixed with a scheme guard, a delegate-based byte cap
(`ByteCapAccumulator`, `Shared/Services/URLContentFetching.swift`), and a dedicated
`URLSession` with both per-request and whole-resource timeouts. See `docs/14-open-
questions.md`'s "Resolved by what actually shipped" section for the audit's other findings
that were deliberately *not* code-fixed (with the reasoning for each) — including
`WidgetState` staying unpopulated and `EventStatus.preparing` staying unproduced, both
intentional and documented there, not oversights to "fix" later.

## Kue 2.0 has started

**Kue 2.0 work has begun. Kue v1.0 is shipped and installed with real SwiftData data in one
App Group store** — every phase from here on must treat that store as real, present, and
non-discardable, not a fixture that can be reset. Phase 1 ("SwiftData Migration Foundation")
is done: `KueSchemaV1` (`Shared/Persistence/Migrations/`) freezes the exact V1.0 model shape,
`KueMigrationPlan` wires it through `ModelContainerFactory`, and `KueTests/Migrations/`
proves a real V1 store round-trips losslessly through it, accepts new writes after migrating,
and those writes persist across a further reopen. See `docs/15-schema-migrations.md` for the
full policy.

**`KueSchemaV1` — i.e. the exact model shape V1.0 shipped — is the migration baseline for
everything Kue 2.0 does.** Every future migration stage in `KueMigrationPlan` starts counting
from it; there is no earlier version, and none should ever be added retroactively "before"
it. **The rule, from here on: every future stored-property change to any `@Model` type
requires a new `VersionedSchema`, a real `MigrationStage` in `KueMigrationPlan`, and a
passing migration test with a representative fixture covering the changed shape — before it
ships, not after.** Do not edit `Shared/Models/*.swift` for a shape change without first
reading `docs/15-schema-migrations.md`'s "How to add a schema version." `KueSchemaV1.swift`
represents a historical snapshot of what real devices already have on disk, not a moving
target — it must never be edited to change what it *represents*. Phase 3 needed one
structural exception: once a later phase actually changes a type's live shape, `KueSchemaV1`
can no longer name that type by its bare (now-repointed) symbol and stay correct, so the
*file* gains a frozen nested copy of exactly the pre-change shape (and, empirically, of every
other `@Model` type with a relationship *to* it — see that file's own header for why the
whole connected subgraph needs this, not just the one type that changed). This is the one
kind of edit `KueSchemaV1.swift` should ever receive: a byte-for-byte nested copy added to
keep the frozen shape nameable, never a semantic change to what V1.0 actually shipped with.

**Physical-device deployment is deferred until final Kue 2.0 sign-off.** Every Kue 2.0 phase
— this one included — is built, migrated, and tested entirely in the iOS Simulator
(`xcodebuild build`/`test` with a `platform=iOS Simulator` destination only); the real V1.0
installation and its data on the project owner's iPhone must stay untouched, and no phase
should run `xcodebuild` against a physical-device destination, alter device
provisioning/signing/registration, or otherwise install/launch a build there, until the
project owner explicitly signs off on the finished Kue 2.0 work and says it's time to deploy.

**Phase 2 ("Search and Event Organization") is done.** `EventListQueryEngine`
(`Shared/Services/`) adds case-/diacritic-insensitive local search (title, location, notes,
event-type display name), independent type/status/archived-scope filters, three sort options
with deterministic tie-breaking, and the three-way empty-database/no-query-results/
no-filter-results distinction; `HomeView` uses the system search control plus a compact
`EventFilterSortSheet`, falling back to the original Upcoming/Active/Completed sections
whenever search/filter/sort are all still at their defaults. `EventDuplicationService`
(`Kue/Services/`) adds "Duplicate Event" from Event Detail — fresh identifiers, regenerated
(never copied) tasks, no carried-over archived/cancelled/manually-completed state, real
duplicate detection, and the same notification-reschedule/widget-reload sequence
`EventFormView.save()` uses for a new event. No stored-property change, no new schema
version — see `docs/16-search-and-organization.md` for the full policy this phase implements.

**Phase 3 ("Recurring Events") is done.** `RecurrenceRule` (`Shared/Models/`) is now a real
Codable contract (frequency, interval, and a mutually-exclusive-by-construction `End`
enum — never/onDate/afterOccurrences); `RecurrenceEngine` (`Shared/Services/`) is the pure
date-math half (anchor-date generation, month-end/leap-year clamping, DST-correct stepping,
the bounded rolling-horizon generator) and `OccurrenceReconciliationService`
(`Kue/Services/`) is the SwiftData-touching half (series creation, idempotent replenishment,
the This Occurrence / This and Future Occurrences edit-and-delete split). A recurring series
is not a new kind of record — it's a set of ordinary `KueEvent` rows (one per materialized
occurrence, each with its own tasks/schedule/widget configuration exactly like a
non-recurring event) sharing a `seriesID`, so every existing per-event mechanism
(notifications, "Next Up," duplicate detection, archival) needed no changes of its own, only
new call sites. This required `KueSchemaV2` (`Shared/Persistence/Migrations/`) — five new
`KueEvent` fields (`seriesID`, `recurrenceAnchorDate`, `isRecurrenceException`, `isSkipped`,
`skippedAt`) and the new `RecurrenceExclusion` model (records a deleted single occurrence's
slot so replenishment never resurrects it) — the first real stage `KueMigrationPlan` has ever
carried. See `docs/17-recurring-events.md` for the full contract, the rolling-horizon
constants and rationale, and the exact edit/delete-scope splitting rules.

**Phase 3 post-implementation cleanup is done.** The combined `KueUITests` suite now passes in
one `xcodebuild test` invocation with no manual simulator erase between classes:
`ModelContainerFactory.uiTestLaunchArgument` (`"-uiTestIsolatedStore"`) — set exclusively via
`XCUIApplication.launchArguments` by every `KueUITests` case — routes `storeURL()` to a location
entirely outside the App Group container, wiped clean at the start of every single launch; this
is a structural safety property (no code path back to the real store URL), not just a flag
check, so it's unreachable in normal production execution. `KueUITests/
UITestLaunchConfiguration.swift` holds the literal (must match the app-side constant exactly,
since `KueUITests` drives the app externally and has no `@testable import Kue`) plus
`resetDeviceOrientation()` (`XCUIDevice.shared.orientation = .portrait` in every test class's
`setUpWithError`, fixing a real cross-launch device-state bug — the simulator's interface
orientation is device-level, not app-scoped, so a rotation left over from one test class
otherwise corrupts every later class's layout math in the same combined run).

**Phase 4 ("Apple Calendar Integration") is done.** `Kue/Services/Calendar/` is the entire
EventKit boundary — `CalendarProviding` (DI protocol), `SystemCalendarProvider` (the one file
that imports `EventKit`), `FakeCalendarProvider` (in-memory, used by both `KueTests` and,
launch-argument-gated exactly like `ModelContainerFactory.isUITestIsolatedStore`, by
`KueUITests`), and `CalendarKitTypes.swift` (the Kue-owned vocabulary — `KueCalendarEvent`,
`CalendarAuthorizationState`, etc. — everything else in the app reads). `CalendarImportPipeline`
(`Kue/Services/Calendar/`) converts a selected Calendar event into an editable `EventDraft`
through the same deterministic normalization every other input path uses; `CalendarExportService`
(`Kue/Services/Calendar/`) is the entire export/update/link-status surface, and either updates
exactly `KueEvent`'s five new linkage fields on success or leaves it completely untouched on
failure — nothing in it ever touches tasks, recurrence, notifications, or the widget. Calendar
integration is explicit and one-shot in both directions; there is no background sync or
observation anywhere in this phase. This required `KueSchemaV3` (`Shared/Persistence/
Migrations/`) — five new nil-defaulted `KueEvent` fields recording an explicit Calendar link —
the second real migration stage `KueMigrationPlan` carries, using the same nested-subgraph
pattern (`KueSchemaV2` now carries a frozen pre-Phase-4 `KueEvent` plus every type with a
relationship to it) `KueSchemaV1` established in Phase 3. See `docs/18-calendar-integration.md`
for the full contract, the authorization-state/import-mapping/export-conflict rules, and what
this phase deliberately doesn't do.

**Phase 5 ("Screenshot and OCR Input") is done.** `Kue/Services/OCR/` mirrors `Services/
Calendar/`'s own shape: `OCRTextRecognizing` (DI protocol), `SystemOCRTextRecognizer` (the one
file that imports `Vision`), `FakeOCRTextRecognizer` (in-memory, launch-argument-gated for
`KueUITests` exactly like `FakeCalendarProvider`), `OCRKitTypes.swift` (Kue-owned vocabulary —
`OCRRecognitionResult`, `OCRConfidence`, `OCRImageLimits`, `OCRRequestGeneration`, etc.), and
`OCRImagePreprocessor.swift` (pure, synchronous validation — encoded size, format, and
dimensions/pixel-count all checked from `CGImageSource` properties *before* any pixel decode,
then one bounded `CGImageSourceCreateThumbnailAtIndex` call that both downsamples and corrects
EXIF orientation). `OCRImportView` (`Kue/Features/OCRImport/`) is Home's "Scan Screenshot" entry
point — `PhotosPicker` (no Photo Library usage description needed; it only ever grants the one
item the user picks), a persistent on-device-disclosure, an editable recognized-text review
screen with a non-color-only low-confidence warning, and explicit retry/choose-another/cancel
actions. Its "Continue" button runs the reviewed text through the *exact* `NLParsingPipeline`
typed NL text already uses — no OCR-specific parser exists anywhere — and hands the resulting
draft to `HomeView.OCRFlowPhase`, the same single-`.sheet(item:)`-content-switches-in-place
shape `CalendarImportPhase` established in Phase 4 (chaining two `.sheet(isPresented:)`
modifiers instead was observed, again, to leave the second sheet presented but empty for this
exact transition). `EventSource` gained one new case, `.ocr` — a plain enum-case addition, no
`@Model` shape change, so **no new schema version was needed** (same as `.calendarImport` in
Phase 4); `KueEvent.schemaVersion` (the separate *semantic* marker) wasn't bumped either, since
no new OCR-specific stored field exists for it to gate — recognized text is never persisted,
only the `EventDraft`/`KueEvent` fields every other input path already writes. `KueApp` also
installs `FakeNLParser`/`FakeAIAvailabilityChecker` (`Kue/Services/FakeNLParser.swift`) whenever
either `FakeOCRTextRecognizer.uiTestLaunchArgument` or (Phase 6)
`FakeVoiceSpeechRecognizer.uiTestLaunchArgument` is present, since Apple Intelligence isn't
available in the iOS Simulator at all and a UI test needs to drive recognized/transcribed text
all the way through parsing deterministically. See `docs/19-screenshot-ocr-input.md` for the
full contract, the documented image-safety limits, and what this phase deliberately doesn't do.

**Phase 6 ("On-Device Voice Input") is done.** `Kue/Services/Voice/` splits into five distinct,
independently dependency-injected responsibilities (requirement 6):
`VoiceAuthorizationChecking` (microphone/speech authorization, checked and requested
independently), `VoiceAudioSessionManaging` (the one file that touches `AVAudioSession`
directly — category/activation/interruption/route-change), `VoiceMicrophoneCapturing` (the one
file that touches `AVAudioEngine` directly — produces raw `AVAudioPCMBuffer`s, has no idea a
recognizer exists), `VoiceSpeechRecognizing` (the one file that imports `Speech` — sets
`requiresOnDeviceRecognition = true` on every request, the structural on-device-only enforcement
mechanism, not just a default Kue happens to leave alone), and `VoiceInputCoordinator`
(`@Observable`, "voice-flow state management" as its own class separate from the view — the only
place that wires the other three together). `VoiceKitTypes.swift` is the Kue-owned vocabulary
(`VoiceAuthorizationState`, `VoiceRecognizerAvailability`, `VoiceRecordingPhase`,
`VoiceTranscriptionUpdate`, `VoiceRequestGeneration`, `VoiceLimits`, etc.) — nothing outside this
folder ever names an `AVAudioSession`/`AVAudioEngine`/`SFSpeechRecognizer` type. Silence
(5s) and maximum-duration (60s) limits are enforced by `VoiceInputCoordinator.tick(now: Date)`, a
pure function of the `now` it's given (exercised deterministically in `KueTests` with synthetic
dates, matching every other time-sensitive engine's own `now: Date` parameter convention) —
`VoiceInputView` drives it in real time via a cancellable sleep-loop `Task`. `VoiceInputView`
(`Kue/Features/VoiceInput/`) is Home's "Voice Input" entry point — record, watch a live partial
transcript, stop and review/edit, then "Continue" runs the transcript through the exact
`NLParsingPipeline` typed NL/OCR text already use, handing the result to
`HomeView.VoiceFlowPhase` (the same single-`.sheet(item:)` shape `OCRFlowPhase` uses). Adding a
fifth trailing toolbar item pushed `HomeView`'s toolbar into iOS's own overflow "More" button,
which silently hid `addEventButton` itself — Import from Calendar/Scan Screenshot/Voice Input
are now one `Menu` ("More Ways to Add," `moreAddOptionsButton`); every affected `KueUITests`
case (Phase 4's, Phase 5's, and Phase 6's own) now opens that menu first, same identifiers
otherwise unchanged. `EventSource` gained one new case, `.voice` — no `@Model` shape change, no
new schema version, no `schemaVersion` bump, same reasoning as `.ocr`/`.calendarImport`. See
`docs/20-voice-input.md` for the full contract, the state-machine diagram, and what this phase
deliberately doesn't do.

**Phase 7 ("Design System and Liquid Glass UI Redesign") is done.** `Kue/DesignSystem/`
(spacing/radius/typography/color/icon-size/motion/haptics/glass tokens, plus `Components/` —
`EventCard`, `PreparationProgressView`, `KueBanner`, `KueStatusStyle`, `KueWordmark`) is the
shared visual layer every screen now reads instead of ad hoc literals; native Liquid Glass
(`.glassEffect`, `.buttonStyle(.glassProminent)`) is used for chrome/controls, never for dense
content, with an opaque Reduce-Transparency fallback (`KueGlass.swift`). `Kue/App/
RootTabView.swift` replaced Home's own toolbar-driven navigation with a five-destination
Liquid Glass bottom `TabView` — Home, Search, **Add** (deliberately the 3rd of 5, genuinely
central), Templates, Settings — each its own `NavigationStack`; selection lives in plain
`@State`, never SwiftData. `Kue/Features/Search/SearchView.swift`, `Kue/Features/AddHub/
AddHubView.swift`, and `Kue/Features/Templates/TemplatesView.swift` (converted from a sheet to
a tab-root screen) are the dedicated pages those destinations now own; `AddHubView` inherited
the exact Calendar-import/OCR/voice `.sheet(item:)` state machinery `HomeView` used to own,
moved verbatim. `HomeView` itself is now a date-sectioned timeline
(`Shared/Services/HomeTimelineGrouping.swift` — pure, `now:`-parameterized, groups by each
event's own pinned-timezone calendar day into Today/Tomorrow/dated sections plus a collapsed
trailing "Later" group past 5 individual sections) with a centered `KueWordmark` header
(`Kue/Assets.xcassets/KueWordmark.imageset`, light/dark asset-catalog variants) as the
toolbar's sole `.principal` item. See `docs/21-design-system.md` for the full architecture,
per-screen redesign notes, and accessibility/motion/haptics decisions.

**Phase 8 ("Expanded and Dedicated Widgets") is done.** `KueWidget` (the existing widget kind)
now supports `.systemLarge` and the three Lock Screen/StandBy accessory families
(`.accessoryCircular`/`.accessoryRectangular`/`.accessoryInline`) alongside small/medium,
unchanged; `.systemExtraLarge` was deliberately not added (iPad-only, and no part of Kue's UI
has ever been given a tested iPad layout — see docs/22 "iPad decision"). A genuinely separate
second widget kind, **`KueDedicatedCountdownWidget`** ("Dedicated Countdown" —
`KueWidget/DedicatedCountdownWidget.swift`/`DedicatedCountdownProvider.swift`/
`DedicatedCountdownConfigurationIntent.swift`/`KueEventEntity.swift`/
`DedicatedCountdownEntryView.swift`), tracks exactly one user-chosen event per placed instance
(WidgetKit's own per-instance `AppIntentConfiguration` storage — no new SwiftData, no schema
change) and **never** falls back to "Next Up": `Shared/Services/
DedicatedWidgetContentService.swift`'s `resolve(event:now:)` is a pure function taking one
optional `KueEvent` (never an events array), returning `.tracking`/`.cancelled`/`.skipped`/
`.unavailable` — its own signature is what makes "can never silently switch events"
structural, not conventional. `Shared/Services/WidgetContentService.swift`'s "Next Up"
eligibility filter was extracted into `isEligibleForAutomaticSelection(_:now:)` (behavior-
preserving refactor) so the shared widget picker (`KueEventEntityQuery`,
search-as-you-type via `EntityStringQuery`, case-/diacritic-insensitive) reuses the identical
rule for what it *suggests*, without duplicating it — resolving an *already*-selected id still
works regardless of that event's current eligibility, so Edit Widget can always show what's
configured. `WidgetIntentActions`'s three intents (`completeTask`/`snoozeTask`/`completeEvent`)
now reload both widget kinds' timelines (`reloadAllWidgetKinds`), since a mutation from either
kind's own button can affect an instance of the other pinned to the same event.
`KueDeepLink.swift` (Shared/) is the one shared `kue://` scheme both `.widgetURL` construction
(KueWidget/) and `RootTabView`'s new `.onOpenURL` parsing agree on — tapping a resolvable
(tracking or cancelled/skipped, since the event still exists) Dedicated widget deep-links to
that event's own Detail screen; a genuinely `.unavailable` one opens `Kue/Features/Widgets/
DedicatedCountdownHelpView.swift`, which states plainly that only the system's own long-press →
Edit Widget can reconfigure that specific placed instance — there is no supported API for an
in-app control to do that, and this phase does not pretend otherwise.
`Shared/DesignSystem/WidgetAccessoryLabels.swift`'s `accessorySafeStatus(phase:subline:)` is
what every accessory-family view (both kinds) reads instead of `WidgetDisplayContent.subline`
directly — `subline` carries a task title (`.preparation`/`.tomorrow`) or the event's location
(`.today`) for those phases, which must never reach an ambient-visible Lock Screen/StandBy
surface (`docs/22` "H. Privacy"); only `.countdown`'s numeric subline is safe to compact
("93 days" → "93d"). `WidgetAccessoryViews.swift` (KueWidget/) holds the accessory family
views shared between both widget kinds, for the identical "don't duplicate status logic across
family views" reason. See `docs/22-expanded-and-dedicated-widgets.md` for the full contract,
terminal-state precedence, and the deferred manual placement/StandBy/Lock-Screen checklist.

## Project structure

```
Shared/                     Claimed by BOTH the "Kue" app target and the "KueWidget"
                             extension target (see "Two targets" below) — only code with
                             zero SwiftUI/WidgetKit/App-only dependencies belongs here.
  Models/                   @Model classes + their Codable/enum types, one file per model
  Persistence/              ModelContainerFactory — the single place the SwiftData schema
                             and ModelContainer are constructed (App Group store, in-memory
                             for tests/previews), plus `ModelContainerOpenOutcome`/
                             `StoreOpenDiagnostic` (Kue 2.0 Phase 1 — `makeDefaultOrDiagnostic()`'s
                             recoverable-failure result type; see that file's own doc comments).
    Migrations/             Kue 2.0 Phase 1. KueSchemaV1.swift (the frozen, exact V1.0 model
                             shape) and KueMigrationPlan.swift. Both read by
                             `ModelContainerFactory.schema`/`.migrationPlan`, which every
                             production target and `makeInMemory()` build from.

                             Kue 2.0 Phase 3 added KueSchemaV2.swift (five new `KueEvent`
                             recurrence fields + the new `RecurrenceExclusion` model — see
                             docs/17-recurring-events.md) and `KueMigrationPlan`'s first real
                             `.custom` stage. This is also the phase that forced
                             `KueSchemaV1.swift` to gain nested, frozen copies of `KueEvent`
                             *and* every type with a relationship to it (`KueTask`,
                             `KueSchedule`, `WidgetConfiguration`, `WidgetState`) — see that
                             file's own header for why the whole connected subgraph needed
                             nesting, not just the one type whose shape actually changed.
  Services/                 EventStatusEngine (status derivation + reconciliation sweep,
                             incl. `archiveThreshold`/`isPastAutoArchiveWindow` — the
                             date-driven auto-archive math both the sweep and the read-only
                             widget extension need), WidgetContentService ("Next Up",
                             lifecycle phase, precomputed transition dates, widget copy,
                             urgent-treatment rule), and WidgetKind (the one `"KueWidget"`
                             literal both targets share) — the original Services/ that moved
                             here, because the widget extension needs them too.

                             Phase 9 (M8) moved four more files here from Kue/Services/ —
                             not rewritten, just relocated — because its widget-extension-
                             executing App Intents need them and `Shared/` is the only place
                             both targets (and `@testable import Kue` in KueTests) can reach:
                             SchedulingEngine.swift (`SnoozeTaskIntent` needs
                             `minimumLeadTime`/`offsetLabel(_:)`), NotificationCandidate.swift
                             + NotificationCandidateBuilder.swift + NotificationScheduling.swift
                             (identifier construction + the `UNUserNotificationCenter` DI seam
                             — `makeRequest()` moved from `Kue/Services/NotificationEngine.swift`
                             into NotificationCandidate.swift and is no longer private, since
                             `SnoozeTaskIntent` needs to build one too), and
                             UserPreferenceStore.swift (`SnoozeTaskIntent` reads
                             `notificationIntensity` before deciding whether to re-add a
                             task-due notification at all). `Kue/Services/NotificationEngine.swift`
                             stays app-only — its full cap-aware global `reschedule` pass is
                             unneeded by any Phase 9 intent, which only ever removes/replaces
                             one event's or one task's identifiers directly.

                             Phase 9 also added: WidgetReloading.swift (the
                             `WidgetCenter.shared.reloadTimelines(ofKind:)` DI seam —
                             `EventActions.reloadWidget()` (Kue/, unchanged) is the app's own
                             call site for the same underlying WidgetKit call; this is the
                             widget-extension-reachable, testable one), TaskSnoozeCalculator.swift
                             (pure `SnoozeTaskIntent` clamp math — docs/07-widget-engine.md's
                             exact bounds — shared by both the intent's `perform()` and
                             `WidgetContentService.displayContent`'s `canSnooze` gate, so
                             "should the button be hidden" and "what would snoozing actually
                             do" can never disagree), and WidgetIntentActions.swift (the
                             actual `completeTask`/`snoozeTask`/`completeEvent` logic —
                             see its own header for why it isn't literally the `AppIntent`
                             structs themselves, and why `completeEvent` narrowly duplicates
                             ~6 lines of `Kue/Services/EventActions.complete` rather than
                             reusing it).

                             Phase 10 (M9) added ShareContent.swift (the extension-item
                             extraction/classification pipeline — `ShareItemProviding` DI seam
                             around `NSItemProvider`, `ShareContentLoader`/
                             `ShareContentNormalizer` — pure, no `NSExtensionContext`, so it's
                             independently testable the same as every other DI seam here) and
                             URLContentFetching.swift (the *one* network call anywhere in
                             Kue — fetching a shared URL's page title, per docs/11-privacy-
                             and-offline.md's explicit exception — with its `<title>`
                             extraction kept as a `static` pure function so tests exercise it
                             against fixed HTML strings, never a real request). Bounded against
                             a Share Extension's tighter memory limit: non-http(s) schemes are
                             rejected before ever opening a connection, `ByteCapAccumulator`
                             (a plain value type, deliberately separate from the
                             `URLSessionDataDelegate` glue around it so it's unit-testable on
                             its own — a stubbed `URLProtocol` delivers its whole response in
                             one call, not the multi-chunk delivery a real transfer does, so it
                             can't itself prove a cap actually stops a read mid-stream) cancels
                             the request once accumulated bytes cross `maxBytesToRead`, and a
                             dedicated `URLSession` sets both `timeoutIntervalForRequest` and
                             `timeoutIntervalForResource` (the latter bounds a slow trickle
                             that keeps resetting the former). Both live here
                             (not KueShare/) because the Share Extension target also
                             synchronizes `Shared/` — see "Three targets" below — and KueTests
                             needs to reach them too.

                             Kue 2.0 Phase 2 added EventListQueryEngine.swift (search
                             normalization, filter/sort/tie-break/empty-reason logic — pure,
                             no SwiftData — see docs/16-search-and-organization.md). Lives in
                             Shared/, not Kue/, on the same "the widget extension might one
                             day need its own filtered list surface too" grounds
                             WidgetContentService already does, even though only `HomeView`
                             (Kue/) uses it today.

                             Kue 2.0 Phase 3 added RecurrenceEngine.swift — pure recurrence
                             date math (anchor-date generation, month-end/leap-year clamping,
                             DST-correct calendar stepping, the bounded rolling-horizon
                             generator) with no SwiftData, same split SchedulingEngine's own
                             `plan(...)` establishes. See docs/17-recurring-events.md.
Kue/                         App-target-only.
  KueApp.swift              App entry point — builds the ModelContainer, sets HomeView as
                             root, sweeps status on scenePhase → .active, and (Phase 8)
                             registers the one `BGAppRefreshTask` launch handler in `init()`
                             (must happen before the app finishes launching; registering the
                             same identifier twice in one process crashes, so this can only
                             run once, which `@main`'s `init()` guarantees).
  Kue.entitlements          App Group capability
  Info.plist                Phase 8 addition — a real file alongside the target's
                             synthesized Info.plist (same `GENERATE_INFOPLIST_FILE` +
                             `INFOPLIST_FILE` combination `KueWidget/Info.plist` already
                             used, with a matching `PBXFileSystemSynchronizedBuildFileExcep
                             tionSet` excluding it from Copy Bundle Resources). Carries
                             `BGTaskSchedulerPermittedIdentifiers`/`UIBackgroundModes`, which
                             have no `INFOPLIST_KEY_*` synthesis equivalent.
  Services/                 App-only pure/testable logic: EventActions (cancel/complete/
                             archive/delete + `reloadWidget()` — Phase 9's widget App Intents
                             use their own `WidgetIntentActions`/`WidgetReloading` (Shared/)
                             instead, since they run in the widget extension process, not
                             here), EventReconciliation (the reusable sweep-then-reload entry
                             point the Phase 8 BGAppRefreshTask handler calls, not re-wire
                             HomeView's logic), EventValidator (form validation),
                             DuplicateDetectionService. `SchedulingEngine` moved to Shared/ in
                             Phase 9 — see that section.

                             Phase 7 (M6) added the NL-AI layer, entirely on-device
                             (FoundationModels) and entirely deterministic downstream of the
                             model call — see docs/06-ai-layer.md: AIAvailability.swift
                             (4-state runtime check, session-cached), AIParsedEventDraft.swift
                             (`@Generable` parser schema), RelativeDateResolver.swift (pure,
                             hand-rolled date-phrase resolver — deliberately not
                             `NSDataDetector`, which has no injectable reference date and so
                             can't be tested deterministically), NLDraftNormalizer.swift
                             (schema/date/range/type validation, never trusts the model's own
                             `startDate`/`endDate` guess over `rawDateText`/`rawEndDateText`),
                             NLParsing.swift (`FoundationModelsParser` + prompt version tag),
                             AIEnvironment.swift (the `\.nlParser`/`\.aiAvailabilityChecker`
                             DI seam — KueApp installs the real implementations; KueTests
                             injects fixtures and never touches `LanguageModelSession`).
                             EventFormView reuses itself as the NL input surface *and* the
                             post-parse confirmation UI (same sheet, pre-filled) rather than
                             a separate screen — docs/09-screens-and-ux.md "same field layout
                             as manual entry, but pre-filled."

                             Phase 8 (M7) added local notifications — docs/08-notifications.md:
                             NotificationCandidate.swift (the `(event, transitionKind)` value
                             type + the doc's exact `eventID-transitionKind` identifier
                             format; `nonisolated` so its `Equatable` conformance works from
                             non-`@MainActor` test bodies, same reason `SchedulingEngine.
                             ScheduledTaskPlan` is), NotificationCandidateBuilder.swift (pure
                             — turns `WidgetContentService.transitionPlan` + `event.tasks`
                             into candidates, excludes archived/cancelled/manually-completed
                             events, applies intensity filtering, and sorts date-ascending-
                             then-tier for the 64-request cap), NotificationScheduling.swift
                             (the `UNUserNotificationCenter` DI seam — `SystemNotification
                             Scheduler` is `nonisolated`, otherwise it can't be used as a
                             default parameter value under `SWIFT_DEFAULT_ACTOR_ISOLATION =
                             MainActor`), NotificationEngine.swift (the SwiftData-touching
                             orchestration — `reschedule` self-heals the *global* desired
                             notification state across every non-archived event on every
                             call, which is what makes cap-trimming and replenishment correct
                             without separate incremental-diff logic; `removeAllNotifications`
                             is the unconditional per-event wipe cancel/complete/archive/
                             delete use), UserPreferenceStore.swift (fetch-or-create the
                             `UserPreference` singleton — moved to Shared/ in Phase 9, see
                             that section), BackgroundTaskScheduling.swift +
                             BackgroundRefreshHandler.swift (the `BGAppRefreshTask` DI seam +
                             handler, shared between notification replenishment and the
                             status-reconciliation sweep per docs/04-event-types.md
                             "Reconciliation" point 2).

                             Phase 10 (M9) added NLParsingPipeline.swift (the "parse, then
                             normalize" orchestration factored out of `EventFormView` so the
                             Share Extension calls the exact same sequence instead of
                             re-deriving it — requirement 4, "do not duplicate parser or
                             validation business logic") and PrivacyActions.swift
                             (`deleteEverything` — docs/11-privacy-and-offline.md's required
                             "delete everything" action, a genuine gap the Phase 10 audit
                             found: declared as a requirement since the doc set's first draft,
                             never actually built in any earlier phase).

                             `EventFormView.save()`/`EditScheduleView.save()` capture an
                             event's prior notification identifiers *before* calling
                             `SchedulingEngine.regenerateTasks` (which deletes the old,
                             non-completed tasks those `-task-<taskID>` identifiers name) —
                             `NotificationEngine.reschedule`'s self-healing can't reconstruct
                             a deleted task's UUID after the fact, so this one step can't be
                             folded into the general reschedule pass. Permission
                             (`requestAuthorization`) is only ever requested from those two
                             call sites (`requestPermissionIfNeeded: true`) — docs/08
                             "requested at the first point it's needed, not at app launch";
                             every other trigger (foreground, background refresh, the
                             idempotent per-event schedule seed) passes `false` and only acts
                             if permission is already decided.

                             Kue 2.0 Phase 2 added EventDuplicationService.swift
                             ("Duplicate Event," docs/16-search-and-organization.md) — copies
                             user-editable fields + schedule rules + widget-configuration
                             settings onto a brand-new `KueEvent`, never a source's identity
                             or cancelled/completed/archived flags; regenerates tasks through
                             `SchedulingEngine` rather than copying `KueTask` rows; runs
                             `DuplicateDetectionService`; reschedules notifications and
                             reloads the widget timeline the same way `EventFormView.save()`
                             does for a new event. App-only for the same reason `EventActions`
                             is — it needs `NotificationEngine`'s full reschedule pass, which
                             no widget-extension App Intent does.

                             Kue 2.0 Phase 3 added OccurrenceReconciliationService.swift — the
                             SwiftData-touching half of docs/17-recurring-events.md: series
                             creation, idempotent/bounded replenishment (called from
                             `EventReconciliation.run` alongside `EventStatusEngine.sweep`),
                             and the This Occurrence / This and Future Occurrences edit-and-
                             delete split. App-only because it takes an `EventDraft`
                             (app-only) and nothing outside the app target ever creates or
                             edits a recurring series. `EventActions` gained `skip`/`unskip` —
                             a third mutually-exclusive user-forceable state alongside cancel/
                             manual-complete, reusing `.cancelled` as its derived `EventStatus`
                             so every existing consumer that already excludes cancelled events
                             excludes a skip for free. `DuplicateDetectionService` gained an
                             `excludingSeriesID:` parameter so sibling occurrences of the same
                             series are never flagged against each other.

                             Kue 2.0 Phase 4 added Calendar/ — the entire EventKit boundary.
                             CalendarProviding.swift (the DI protocol every view/service reads
                             via `\.calendarProvider`, CalendarEnvironment.swift), Calendar
                             KitTypes.swift (Kue-owned vocabulary — `KueCalendarEvent`,
                             `CalendarAuthorizationState`, etc. — nothing outside this folder
                             ever names an EventKit type), SystemCalendarProvider.swift (the
                             one file that imports `EventKit`), FakeCalendarProvider.swift
                             (in-memory; used by `KueTests` and, launch-argument-gated exactly
                             like `ModelContainerFactory.isUITestIsolatedStore`, installed by
                             `KueApp` in place of the real provider for `KueUITests`),
                             CalendarImportPipeline.swift ("convert → normalize → editable
                             draft," the same shape NLParsingPipeline establishes, applied to a
                             selected Calendar event), and CalendarExportService.swift (export/
                             update/link-status — updates exactly `KueEvent`'s five new linkage
                             fields on success, leaves it untouched on failure, never touches
                             tasks/recurrence/notifications/widget). See docs/18-calendar-
                             integration.md for the full contract.

                             Kue 2.0 Phase 5 added OCR/ — the same shape as Calendar/ above,
                             for Vision. OCRTextRecognizing.swift (DI protocol, read via
                             `\.ocrTextRecognizer`, OCREnvironment.swift), OCRKitTypes.swift
                             (Kue-owned vocabulary — `OCRRecognitionResult`, `OCRConfidence`,
                             `OCRImageLimits`, `OCRRequestGeneration` — nothing outside this
                             folder ever names a Vision type), SystemOCRTextRecognizer.swift
                             (the one file that imports `Vision`), FakeOCRTextRecognizer.swift
                             (in-memory; same launch-argument-gated installation pattern as
                             FakeCalendarProvider), and OCRImagePreprocessor.swift (pure,
                             synchronous — encoded size/format/dimensions/pixel-count all
                             checked from `CGImageSource` properties before any pixel decode,
                             then one bounded `CGImageSourceCreateThumbnailAtIndex` call that
                             both downsamples and corrects EXIF orientation). FakeNLParser.swift
                             (Services/, not Services/OCR/ — it fakes the *existing*
                             `NLParsing`/`AIAvailabilityChecking` seam, not a new one) is
                             installed by `KueApp` alongside `FakeOCRTextRecognizer.uiTest
                             LaunchArgument` since Apple Intelligence isn't available in the iOS
                             Simulator at all. See docs/19-screenshot-ocr-input.md for the full
                             contract, the documented image-safety limits, and the downsampling
                             policy.

                             Kue 2.0 Phase 6 added Voice/ — five separate DI-injected
                             responsibilities (requirement 6). VoiceAuthorizationChecking.swift/
                             VoiceAudioSessionManaging.swift/VoiceMicrophoneCapturing.swift/
                             VoiceSpeechRecognizing.swift (protocols, read via
                             `\.voiceAuthorizationChecker`/`\.voiceAudioSessionManager`/
                             `\.voiceMicrophoneCapture`/`\.voiceSpeechRecognizer`,
                             VoiceEnvironment.swift), VoiceKitTypes.swift (Kue-owned vocabulary —
                             `VoiceAuthorizationState`, `VoiceRecognizerAvailability`,
                             `VoiceRecordingPhase`, `VoiceTranscriptionUpdate`,
                             `VoiceRequestGeneration`, `VoiceLimits` — nothing outside this
                             folder ever names an `AVAudioSession`/`AVAudioEngine`/
                             `SFSpeechRecognizer` type), SystemVoiceAuthorizationChecker.swift/
                             SystemVoiceAudioSessionManager.swift/
                             SystemVoiceMicrophoneCapture.swift/SystemVoiceSpeechRecognizer.swift
                             (the one file each that touches its own real framework — the last
                             one sets `requiresOnDeviceRecognition = true` on every request, the
                             structural on-device-only enforcement mechanism), FakeVoiceServices.
                             swift (all four fakes; same launch-argument-gated installation
                             pattern as FakeCalendarProvider/FakeOCRTextRecognizer, all gated
                             together under one argument since a UI test needs every one faked
                             at once), and VoiceInputCoordinator.swift (`@Observable` —
                             "voice-flow state management" as its own class, the only place the
                             other four services are wired together; `tick(now: Date)` is a pure
                             function of the `now` it's given, so silence/max-duration logic is
                             exercised deterministically with synthetic dates). See
                             docs/20-voice-input.md for the full contract, the state-machine
                             diagram, and the duration/silence-limit rationale.
  Features/<Screen>/        One SwiftUI view (+ its own small subviews) per screen. Views
                             stay thin — they call into Services/, they don't recompute
                             status, validate fields, or plan schedules themselves.
                             Templates/ (built-in Interview/Exam/Trip/Deadline picker — no
                             `Template` rows persisted, just `SchedulingEngine.defaultRules`)
                             and EditSchedule/ (custom `ScheduleRule` list/add/edit/delete)
                             are Phase 6 additions; both still route every mutation through
                             `SchedulingEngine.regenerateTasks` — neither ever inserts a
                             `KueTask` directly. Settings/ gained its notification-intensity
                             picker and persistent permission-status indicator in Phase 8, and
                             (Phase 10 audit) an AI on/off toggle and Privacy's "Delete
                             Everything"; Appearance remains unbuilt (`docs/14-open-
                             questions.md` — no doc specifies what it would control).
                             EventForm/EventFormView.swift gained a second initializer in
                             Phase 10 — `init(prefilledDraft:ambiguities:source:)` — the Share
                             Extension's entry point into this same confirmation UI, still
                             `.add` mode under the hood (identical `save()`/duplicate-check
                             path); see that init's own doc comment.

                             Kue 2.0 Phase 3 added a "Repeat" section to EventFormView
                             (frequency/interval/end controls, a live human-readable summary,
                             and — when editing an occurrence already in a series — a required
                             This Occurrence / This and Future Occurrences scope picker routed
                             through `OccurrenceReconciliationService.applyEdit`) and, to
                             EventDetailView, Skip/Un-skip actions and a two-scope delete
                             confirmation for a series occurrence (each button states its own
                             scope, per docs/17-recurring-events.md "Occurrence actions" /
                             "Deleting one occurrence"). All decision-making stays in
                             `OccurrenceReconciliationService`/`EventActions`; both views only
                             orchestrate which call to make and present the result.

                             Kue 2.0 Phase 4 added CalendarImport/CalendarImportListView.swift
                             (Home's "Import from Calendar" entry point — authorization-gated
                             event list, occurrence-vs-series choice for a recurring selection,
                             hands an already-built `EventDraft` back to `HomeView`, never
                             creates a `KueEvent` itself) and Detail/
                             CalendarDestinationPickerView.swift (destination-calendar picker
                             for export, reached from EventDetailView's new "Add to Apple
                             Calendar" action). `HomeView` presents the import flow as one
                             continuous `.sheet(item:)` whose content switches between the
                             picker and the prefilled form (`CalendarImportPhase`) rather than
                             two chained `.sheet(isPresented:)` modifiers the way Templates'
                             flow works — see that type's own doc comment for why. EventDetail
                             View gained a Calendar-actions section (Add to Apple Calendar /
                             Update Calendar Event / Unlink, a link-status row, and confirmation
                             dialogs for the missing-event and externally-modified-conflict
                             cases) and SettingsView gained a Calendar section (authorization
                             state, explanation, "Allow Calendar Access" when not yet
                             determined) mirroring the Notifications section's own shape.

                             Kue 2.0 Phase 5 added OCRImport/OCRImportView.swift — Home's "Scan
                             Screenshot" entry point: `PhotosPicker` (no Photo Library usage
                             description needed — it only ever grants the one item picked),
                             a persistent on-device-processing disclosure, an editable
                             recognized-text review screen with a non-color-only low-confidence
                             warning, and explicit retry/choose-another/cancel actions. Its
                             "Continue" button runs the reviewed text through the exact
                             `NLParsingPipeline` typed NL text already uses — no OCR-specific
                             parser exists — and hands the draft to `HomeView.OCRFlowPhase`, the
                             same single-`.sheet(item:)`-content-switches-in-place shape
                             `CalendarImportPhase` uses, for the identical reason.

                             Kue 2.0 Phase 6 added VoiceInput/VoiceInputView.swift — Home's
                             "Voice Input" entry point: record, watch a live partial transcript
                             (read-only while recording), stop and review/edit the final
                             transcript, then "Continue" runs it through the exact same
                             `NLParsingPipeline`. Its own five phases
                             (idle/recording/finalizing/reviewing/noSpeechDetected/error) are
                             `VoiceInputCoordinator`'s, not this view's own — the view only
                             renders `coordinator.phase` and forwards taps to coordinator
                             methods. Uses `\.openURL`, not `UIApplication.shared.open(_:)`, for
                             its "Open Settings" recovery button — this file (like every other
                             Kue/ file) is also synchronized into the KueShare extension target,
                             where `UIApplication.shared` doesn't compile. Hands the draft to
                             `HomeView.VoiceFlowPhase`, the same single-`.sheet(item:)` shape
                             `OCRFlowPhase` uses; its own recovery states can hand off to manual
                             entry or Scan Screenshot via the same dismiss-then-present-in-
                             `onDismiss` sequencing `presentAddForPendingTemplate` already uses.
                             `HomeView`'s toolbar collapsed Import from Calendar/Scan Screenshot/
                             Voice Input into one `Menu` ("More Ways to Add",
                             `moreAddOptionsButton`) once this fifth trailing item pushed the
                             toolbar into iOS's own overflow "More" button, which silently hid
                             `addEventButton` itself — confirmed via a UI test failure, not
                             assumed; every affected `KueUITests` case across Phases 4/5/6 now
                             opens that menu first.
                             Home/EventFilterSortSheet.swift — Kue 2.0 Phase 2's compact
                             filter/sort sheet (docs/16-search-and-organization.md). Pure
                             SwiftUI over `HomeView`'s own `@State` bindings, no business
                             logic — every predicate/ordering decision lives in
                             `EventListQueryEngine` (Shared/). `HomeView` itself gained
                             `.searchable` (the system search control) and switches between
                             its original three-section layout and a flat sorted results list
                             depending on whether search/filter/sort are all still default.

                             StoreRecovery/StoreOpenFailureView.swift — Kue 2.0 Phase 1,
                             requirement 9's "recoverable diagnostic path": shown by KueApp
                             instead of HomeView when `ModelContainerFactory.
                             makeDefaultOrDiagnostic()` fails. Not a 2.0 product feature —
                             baseline persistence-failure safety net every phase from here on
                             depends on; no "delete and start fresh" action on purpose (see
                             that file's own header).
KueWidget/                   Widget-extension-target-only: KueWidgetBundle (@main),
                             KueWidget (the Widget), KueEventProvider
                             (AppIntentTimelineProvider — a thin wrapper over
                             WidgetContentService, owns no phase math itself),
                             KueWidgetConfigurationIntent + KueEventEntity/Query (the
                             configuration picker), KueWidgetEntryView, Info.plist,
                             KueWidget.entitlements.

                             Phase 9 (M8) added the three interactive-widget App Intents —
                             docs/07-widget-engine.md "Interactive widgets": CompleteTaskIntent,
                             SnoozeTaskIntent, CompleteEventIntent. Each is a thin `AppIntent`
                             wrapper (no `openAppWhenRun` override — the protocol default is
                             `false`, which is what lets them run without launching the app):
                             parse the `@Parameter var …IDString: String` (plain `String`, not
                             `UUID` — `UUID` doesn't conform to the value types `@Parameter`
                             supports), open the shared store via
                             `ModelContainerFactory.makeDefaultOrNil()`, call the matching
                             `WidgetIntentActions` function (Shared/) with the live
                             `SystemNotificationScheduler`/`SystemWidgetReloader`, and return
                             `.result(dialog:)`. `KueWidgetEntryView`'s `Button(intent:)`s call
                             these directly; `WidgetDisplayContent.canSnooze` (Shared/) is what
                             hides — not disables — the snooze button once
                             `TaskSnoozeCalculator.isSnoozeAvailable` says no valid interval
                             remains.
KueShare/                    Share-Extension-target-only (Phase 10 / M9) — docs/01-vision-
                             and-scope.md "V1 input paths" / docs/12-roadmap-and-
                             milestones.md "Phase 10 — Share Extension". ShareViewController
                             (the `NSExtensionPrincipalClass`, no storyboard — gathers this
                             share's `NSItemProvider`s and the real dependencies, hands off to
                             SwiftUI), ShareExtensionRootView (the actual flow: load →
                             normalize → fetch a URL's title if needed → `NLParsingPipeline` →
                             present the *same* `EventFormView` sheet typed NL input uses, via
                             its `prefilledDraft` init — see that file's header for the full
                             sequence and every fallback path), NSItemProviderAdapter (the
                             one-file retroactive `NSItemProvider: ShareItemProviding`
                             conformance — real extension glue, not testable, kept out of
                             Shared/ on purpose), Info.plist (`NSExtensionActivationRule`:
                             text + web URL/web page, per docs/01 "text/URL only"),
                             KueShare.entitlements (same App Group as the other two targets).

                             This target's `fileSystemSynchronizedGroups` include `Kue/`
                             itself (not just `Shared/`) — its own exception set on the `Kue/`
                             root group excludes only `KueApp.swift`/`Info.plist`/
                             `Kue.entitlements`, so `EventFormView` and everything it
                             transitively needs (the NL-AI layer, `EventActions`,
                             `DuplicateDetectionService`, ...) compile into KueShare verbatim
                             — zero duplication, requirement 4. See docs/14-open-questions.md
                             for why this was chosen over moving that code into `Shared/`.
KueTests/                   Swift Testing (`import Testing`) unit tests — `@testable import
                             Kue` sees everything in Shared/ and Kue/, since both compile
                             into the "Kue" module. There's no separate widget test target;
                             WidgetContentService's testability is *why* it lives in Shared/.
                             Phase 8's fakes (FakeNotificationScheduler,
                             FakeBackgroundTaskScheduler, FakeBackgroundTask) live in
                             NotificationTestSupport.swift, shared across its test files —
                             no test here ever touches a real `UNUserNotificationCenter` or
                             `BGTaskScheduler`. Phase 9 added FakeWidgetReloader to the same
                             file (same rationale) and tests
                             `WidgetIntentActions`/`TaskSnoozeCalculator` directly — the
                             `CompleteTaskIntent`/`SnoozeTaskIntent`/`CompleteEventIntent`
                             `AppIntent` structs themselves live in KueWidget/, which
                             `@testable import Kue` can't see, so they're deliberately kept
                             as thin, untested-directly wrappers around logic that is tested.
                             Phase 10 added ShareContentTests.swift, URLContentFetcherTests
                             .swift, NLParsingPipelineTests.swift,
                             EventFormViewPrefilledInitTests.swift, PrivacyActionsTests.swift
                             — same principle: `KueShare/`'s own `AppIntent`-equivalent
                             (`ShareViewController`/`ShareExtensionRootView`) is untestable
                             from here, so the tested surface is everything reachable
                             (`ShareContentLoader`/`ShareContentNormalizer`,
                             `SystemURLContentFetcher.extractTitle`, `NLParsingPipeline`,
                             `EventFormView`'s prefilled init, `PrivacyActions`). Verifying the
                             Share Extension's own UI end to end (duplicate banner, cancel,
                             successful creation, actually invoked from Safari/Mail/Messages)
                             is a manual-device check — Share Extensions have no launchable
                             icon of their own for `XCUIApplication` to drive, a platform
                             limitation, not a shortcut taken here.
                             Kue 2.0 Phase 2 added EventListQueryEngineTests.swift (search
                             normalization, every filter alone/combined, every sort option,
                             tie-breaking stability, all four empty-reason outcomes — plain
                             in-memory `KueEvent` fixtures, no ModelContext) and
                             EventDuplicationServiceTests.swift (every event type, fresh
                             identifiers, independent relationships, regenerated-not-copied
                             tasks, custom-schedule-rule preservation, no carried-over
                             archived/cancelled/manually-completed state, duplicate detection,
                             notification/widget invocation via the same
                             FakeNotificationScheduler/FakeWidgetReloader
                             NotificationTestSupport.swift already provides).

                             Kue 2.0 Phase 3 added RecurrenceEngineTests.swift (every
                             frequency, intervals > 1, both end kinds, validation failures,
                             month-end/leap-year clamping, DST spring-forward/fall-back,
                             nonexistent/repeated local times, timezone pinning, the bounded
                             rolling-horizon generator's minimum/maximum/idempotency behavior,
                             and the human-readable summary — pure, no ModelContext) and
                             OccurrenceReconciliationServiceTests.swift (series/occurrence
                             identity, deterministic per-occurrence task generation through
                             `SchedulingEngine`, idempotent/duplicate-free replenishment,
                             explicit exceptions surviving reconciliation, This Occurrence and
                             This and Future edits, and deletion with `RecurrenceExclusion`).
                             DuplicateDetectionServiceTests.swift, NotificationCandidate
                             BuilderTests.swift, WidgetLifecycleTests.swift, and
                             EventCRUDTests.swift each gained a small addition for the
                             recurrence-specific case they cover (series exclusion, skip
                             excluded from candidates, skip excluded from "Next Up", skip/
                             unskip action behavior) rather than new files, since each already
                             held the exact fixture/assertion style that case needed.
    Migrations/             Kue 2.0 Phase 1 — reusable migration-test infrastructure, not a
                             one-off. MigrationTestSupport.swift (real, on-disk stores at a
                             throwaway temp URL — *never* the production App Group path;
                             `makeV1Store` reconstructs the historical, pre-migration-plan
                             construction every real device's store was actually built with,
                             `reopenThroughCurrentMigrationPlan` reopens it through
                             `ModelContainerFactory`'s real, current wiring), MigrationFixtures
                             .swift (representative data across every V1 event type, all-day/
                             timed, completed tasks, custom schedules, widget configuration,
                             notification preferences, cancellation, manual completion,
                             archived records — plus a `Snapshot` type everything is checked
                             against after a reopen, since a reopened container hands back
                             *new* model instances, not the ones inserted), SchemaV1Migration
                             Tests.swift (the actual proof — see docs/15-schema-migrations.md).
                             Reuse these three files' patterns for every future schema
                             version's own migration test. Kue 2.0 Phase 3 added
                             SchemaV2MigrationTests.swift — reuses the same fixtures, proving
                             every migrated V1 row gets non-recurring defaults for the five new
                             fields, `RecurrenceExclusion` is part of the migrated schema, and
                             genuinely new (post-migration) recurring data — a series, an
                             exception, an exclusion — round-trips through a further reopen.
                             `MigrationFixtures.swift` itself now builds its five fixture
                             events as `KueSchemaV1.KueEvent` (not the live `KueEvent`) since
                             that's the type a real V1-schema-only store actually holds — see
                             `KueSchemaV1.swift`'s own header. Kue 2.0 Phase 4 added
                             CalendarAuthorizationTests.swift, CalendarImportPipelineTests.swift,
                             CalendarImportFlowTests.swift, CalendarExportServiceTests.swift
                             (every authorization state, import mapping rule, explicit-
                             confirmation/duplicate-detection integration, and export/update/
                             missing/conflict/unlink/failure behavior — `FakeCalendarProvider`
                             only, never `EKEventStore`) and Migrations/
                             SchemaV3MigrationTests.swift (same reused fixtures/support, proving
                             the five new Calendar-linkage fields nil-backfill and genuinely new
                             linked data survives a further reopen). Kue 2.0 Phase 5 added
                             OCRImageValidationTests.swift (formats, corrupt/malformed/oversized
                             data, dimension/pixel-count limits, downsampling decisions, EXIF
                             orientation correction — every fixture image generated at test time
                             via Core Graphics, never a bundled binary asset), OCRRecognition
                             Tests.swift (confidence aggregation, low-confidence/no-text
                             behavior, text normalization/line ordering, the
                             `OCRTextRecognizing` seam itself), and OCRFlowTests.swift
                             (`OCRRequestGeneration` cancellation/stale-result/retry semantics,
                             parser routing through the real `NLParsingPipeline`, ambiguity
                             handling, duplicate detection, explicit confirmation,
                             `EventSource.ocr`, no persistence before confirmation,
                             notification/widget side effects after a confirmed OCR-sourced
                             event) — all `FakeOCRTextRecognizer`-only, never `Vision`. Kue 2.0
                             Phase 6 added VoiceAuthorizationTests.swift (every authorization-
                             state combination, no permission request before contextual
                             education, on-device availability, a structural proof there is no
                             recognizer-availability case that permits recording without
                             on-device support), VoiceRecognitionTests.swift (confidence
                             aggregation, ordering, stale-result suppression via
                             `VoiceRequestGeneration`, user-edit preservation, no-speech/failure
                             outcomes), and VoiceCoordinatorTests.swift (start/stop/cancel/retry,
                             silence/max-duration via synthetic `tick(now:)` dates, interruption,
                             route change, duplicate-session prevention, audio-session cleanup,
                             parser routing, ambiguity, duplicate detection, explicit
                             confirmation, `EventSource.voice`, no persistence before
                             confirmation, cleanup after every termination path, notification/
                             widget effects after confirmed creation) — all four Fake* Voice
                             services only, never real `AVAudioSession`/`AVAudioEngine`/`Speech`.
KueUITests/                  XCTest UI tests — Kue 2.0 Phase 2 added
                             SearchAndOrganizationUITests.swift (search, clearing search,
                             the filter/sort sheet, filtering to one event type, sorting,
                             an unmatched-search empty state, duplication) — same unique-
                             per-run-title convention as EventManagementUITests/
                             TemplateAndScheduleUITests, since the app's real on-disk store
                             persists across UI test runs. Kue 2.0 Phase 3 added
                             RecurringEventsUITests.swift (creating each recurrence type, the
                             recurrence summary, validation errors, This Occurrence / This and
                             Future Occurrences editing, skip, complete, delete with its scope
                             confirmation) — same convention, plus two Phase-3-specific ones:
                             it searches for a just-created event by its own unique title
                             (Home's `.searchable`) rather than assuming it's immediately
                             visible, since a fresh zero-duration event is often already
                             `.completed` by the time `save()` runs and Home's default
                             sectioned layout doesn't guarantee it's on-screen without
                             scrolling; and it identifies one exact occurrence among several
                             sharing the same title by each row's own title+date label, not
                             the bare title alone. Kue 2.0 Phase 4 added
                             CalendarIntegrationUITests.swift (Settings/authorization
                             presentation, contextual permission education, denied/restricted
                             states, import selection, editable imported draft + explicit
                             confirmation, export confirmation, update presentation, missing-
                             event handling, conflict handling) — same isolated-store convention
                             as every other class here, launched with an additional
                             `fakeCalendarArgument` (plus, for specific states/fixtures, one of
                             `UITestLaunchConfiguration`'s other `fakeCalendar*Argument`
                             constants) that `KueApp` matches against
                             `FakeCalendarProvider`'s own identical literals to install a fake
                             provider instead of `SystemCalendarProvider` — never the real
                             EventKit database. Kue 2.0 Phase 5 added OCRImportUITests.swift
                             (opening the flow, the on-device privacy disclosure, the loading
                             state, successful recognized-text review, editing recognized text,
                             the low-confidence warning, the no-text state, failure and retry,
                             choosing another image, cancelling, continuing into parsing/
                             confirmation, confirming the final event) — same convention,
                             launched with `fakeOCRArgument` (plus, for specific results, one of
                             `UITestLaunchConfiguration`'s other `fakeOCR*Argument` constants);
                             `\.ocrUsesFixtureImageSource` swaps `OCRImportView`'s real
                             `PhotosPicker` for a deterministic "Choose Test Image" button under
                             that same argument — never the owner's real Photos library or
                             uncontrolled Vision output. Kue 2.0 Phase 6 added
                             VoiceInputUITests.swift (opening Voice input, contextual microphone/
                             speech permission education, the privacy disclosure, denied/
                             restricted states, on-device-unavailable, starting recording, live
                             partial transcription, the visible recording state and duration,
                             stopping/finalizing, editing transcription, silence — a real ~5–8s
                             wall-clock wait for `VoiceLimits.silenceTimeout`, deliberately
                             slower than the rest of this file — interruption via
                             `FakeVoiceAudioSessionManager.simulateInterruptionAfterNanoseconds`,
                             retry, cancelling, continuing through parsing, confirming the final
                             event) — launched with `fakeVoiceArgument` (plus, for specific
                             states, one of `UITestLaunchConfiguration`'s other
                             `fakeVoice*Argument` constants); `KueApp` installs all four fake
                             Voice services together under that one argument — never the
                             simulator's or owner's real microphone.
```

A `Utilities/` folder doesn't exist yet — it'll appear when something is actually generic
enough to live there. Don't pre-create empty folders or placeholder types for subsystems
that haven't started; that's exactly the kind of speculative scaffolding this project
deliberately avoids.

All folders above are Xcode file-system-synchronized groups — adding a `.swift` file under
the right directory is enough; you do not need to edit `project.pbxproj` by hand.
**Exception:** `Shared/` is synchronized to *three* targets at once (Kue, KueWidget, and
KueShare all list it in their `fileSystemSynchronizedGroups`) and `Kue/` to *two* (Kue and,
since Phase 10, KueShare too) — that's what makes one copy of `ModelContainerFactory`/the
`@Model` types/`EventFormView`/etc. compile into multiple targets without a shared framework.
If a file needs App-only (Kue-target-specific, e.g. `@main`) or Widget-only imports, it does
not belong in `Shared/`. A build *setting* change (not just adding a source file) — like
Phase 8's `Kue/Info.plist` wiring, or a whole new target (Phase 4's KueWidget, Phase 10's
KueShare) — still requires a direct `project.pbxproj` edit.

### Three targets: Kue (app) + KueWidget (extension) + KueShare (extension)

Kue+KueWidget added in Phase 4; KueShare added in Phase 10. All three join the App Group
`group.com.kanishkgandecha.Kue` (`docs/03-data-model.md` "Shared storage: App Group") so
`ModelContainerFactory.makeDefault()` opens the *same* on-disk store in every process — never
a copy or snapshot. Both extensions must call `ModelContainerFactory.makeDefaultOrNil()` (not
`makeDefault()`), since a broken store there should degrade gracefully (a placeholder widget
entry; an alert + no-op in the Share Extension), never crash the extension process
(`docs/13-error-handling.md` "Widget refresh failure" — the same principle applies to Share).

All three targets currently use `CODE_SIGN_STYLE = Manual` with an ad-hoc identity (`-`) —
this environment has no Apple Developer Team configured, and automatic signing silently
strips App-Group-dependent entitlements from the final signature when there's no team to
validate the capability against (confirmed empirically while building this out: the
pre-strip "-Simulated.xcent" intermediate keeps the entitlement, but automatic signing's
*actual* signed output does not, regardless of Automatic vs Manual). On a machine with a real
(even free Personal) Team signed into Xcode, switching back to Automatic should work
identically or better — do that if it becomes available rather than assuming Manual is a
permanent requirement.

Adding KueShare itself required direct `project.pbxproj` edits (a brand-new
`PBXNativeTarget`, same category of change as Phase 4's original widget-target addition) —
build-setting/target-graph changes still can't be done by dropping files into a folder alone.
It mirrors KueWidget's `com.apple.product-type.app-extension` product type and
`GENERATE_INFOPLIST_FILE` + `INFOPLIST_FILE` + exception-set pattern exactly, plus the second
`fileSystemSynchronizedGroups` entry on `Kue/` described in the KueShare/ project-structure
entry above.

Kue 2.0 Phase 4's `INFOPLIST_KEY_NSCalendarsFullAccessUsageDescription`/
`INFOPLIST_KEY_NSCalendarsWriteOnlyAccessUsageDescription` are set only on the **Kue app
target's** Debug/Release configurations — never KueWidget's or KueShare's, which never touch
Calendar and must not carry the capability. Calendar access needs no App-Group-style
entitlement (just the Info.plist keys), so this was a pure `project.pbxproj` build-setting edit,
same category of change as the KueShare target addition above.

Kue 2.0 Phase 6's `INFOPLIST_KEY_NSMicrophoneUsageDescription`/
`INFOPLIST_KEY_NSSpeechRecognitionUsageDescription` are, likewise, set only on the Kue app
target's Debug/Release configurations. `Kue/Services/Voice/`/`Kue/Features/VoiceInput/` still
*compile into* KueShare (the whole `Kue/` folder is synchronized to it), but KueShare's own
Info.plist never declares either capability and its runtime never calls into either API — same
"code present, capability not declared, never actually invoked" pattern Calendar/Photos code in
KueShare already established in Phases 4/5.

## Build & test

```bash
# Build
xcodebuild build -project Kue.xcodeproj -scheme Kue \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# Unit tests (KueTests target)
xcodebuild test -project Kue.xcodeproj -scheme Kue \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:KueTests

# Combined UI tests (KueUITests target) — every class in one invocation, no manual simulator
# erase needed between them; see ModelContainerFactory.isUITestIsolatedStore/
# UITestLaunchConfiguration above for why this is safe.
xcodebuild test -project Kue.xcodeproj -scheme Kue \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:KueUITests
```

Fix every error and warning introduced by your own change before considering it done —
a clean `xcodebuild build` and passing `KueTests` is the minimum bar for any commit, not
just Phase 1. The `Kue` scheme builds all three product targets (Kue app, KueWidget,
KueShare — Kue depends on both extensions and embeds them), so the one `xcodebuild build`
above already covers "build the main app, widget extension, and Share Extension." `xcodebuild
build -scheme KueShare` builds it standalone if you need to isolate a Share-Extension-only
build issue.

Deployment target is iOS 26.5, set in Phase 1 — this is what backs the on-device AI
requirement above; don't lower it without updating `docs/14-open-questions.md`'s
deployment-target entry.

### A module-wide concurrency quirk worth knowing before you hit it

Both the Kue and KueWidget targets set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every
type/function declared in this module defaults to MainActor isolation unless marked
`nonisolated`. Two concrete traps this has already caused, both fixed by adding
`nonisolated` at the declaration:

- A plain value type (e.g. `SchedulingEngine.ScheduledTaskPlan`, `NotificationCandidate`)
  compared via Swift Testing's `#expect` needs `nonisolated`, or its (also
  MainActor-isolated-by-default) `Equatable` conformance can't be used from a test body
  that isn't itself `@MainActor`.
- A class referenced as a **default parameter value** (e.g. `SystemNotificationScheduler.
  shared`) needs `nonisolated` on the class itself — default-argument expressions are
  isolation-checked independently of the function they belong to, regardless of that
  function's own actor.
- `AppIntent.perform()` (Phase 9) is treated as running outside the actor even though the
  conforming struct isn't marked `nonisolated` — calling any MainActor-isolated function
  from inside it (`ModelContainerFactory.makeDefaultOrNil()`, `WidgetIntentActions.*`) needs
  an explicit `await`, same fix as calling one MainActor-isolated function from another in a
  test body (`await EventActions.archive(...)`), not a `nonisolated` declaration change.

## Git

Git operations (commit, branch, push, etc.) in this repository are handled by the human
maintainer. Do not run `git` commands as part of implementing a feature unless
explicitly asked to.
