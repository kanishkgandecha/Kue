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
- **Phases build in order.** V1 (Phases 1–10 / M0–M9) is now complete — see "Current
  implementation status" below. Any *new* work is post-V1 (`docs/01-vision-and-scope.md`
  "What NOT to build in V1": OCR, Voice, calendar integration, context engine, Live
  Activities, large/Lock Screen widgets, user-defined templates, ...) and needs the project
  owner to explicitly say V1's done and post-V1 work has started before you add it.

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

## Project structure

```
Shared/                     Claimed by BOTH the "Kue" app target and the "KueWidget"
                             extension target (see "Two targets" below) — only code with
                             zero SwiftUI/WidgetKit/App-only dependencies belongs here.
  Models/                   @Model classes + their Codable/enum types, one file per model
  Persistence/              ModelContainerFactory — the single place the SwiftData schema
                             and ModelContainer are constructed (App Group store, in-memory
                             for tests/previews)
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
KueUITests/                  XCTest UI tests
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

## Build & test

```bash
# Build
xcodebuild build -project Kue.xcodeproj -scheme Kue \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# Unit tests (KueTests target)
xcodebuild test -project Kue.xcodeproj -scheme Kue \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:KueTests
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
