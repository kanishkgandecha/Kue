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
- **Phases build in order.** Don't implement a later phase's behavior early — e.g. no
  scheduling engine, widgets, notifications, AI parsing, or Share Extension code until
  `docs/12-roadmap-and-milestones.md` says that phase has started. Check the current phase
  before adding a subsystem.

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
                             literal both targets share) — the only Services/ that moved
                             here, because the widget extension needs them too.
Kue/                         App-target-only.
  KueApp.swift              App entry point — builds the ModelContainer, sets HomeView as
                             root, sweeps status on scenePhase → .active
  Kue.entitlements          App Group capability
  Services/                 App-only pure/testable logic: EventActions (cancel/complete/
                             archive/delete + `reloadWidget()`), EventReconciliation (the
                             reusable sweep-then-reload entry point — Phase 9's App Intents
                             and a future BGAppRefreshTask handler should call this, not
                             re-wire HomeView's logic), EventValidator (form validation),
                             DuplicateDetectionService, SchedulingEngine (task generation).
                             Notification/AI-parser logic will land here the same way in
                             their own phases.
  Features/<Screen>/        One SwiftUI view (+ its own small subviews) per screen. Views
                             stay thin — they call into Services/, they don't recompute
                             status, validate fields, or plan schedules themselves.
KueWidget/                   Widget-extension-target-only: KueWidgetBundle (@main),
                             KueWidget (the Widget), KueEventProvider
                             (AppIntentTimelineProvider — a thin wrapper over
                             WidgetContentService, owns no phase math itself),
                             KueWidgetConfigurationIntent + KueEventEntity/Query (the
                             configuration picker), KueWidgetEntryView, Info.plist,
                             KueWidget.entitlements.
KueTests/                   Swift Testing (`import Testing`) unit tests — `@testable import
                             Kue` sees everything in Shared/ and Kue/, since both compile
                             into the "Kue" module. There's no separate widget test target;
                             WidgetContentService's testability is *why* it lives in Shared/.
KueUITests/                 XCTest UI tests
```

A `Utilities/` folder doesn't exist yet — it'll appear when something is actually generic
enough to live there. Don't pre-create empty folders or placeholder types for subsystems
that haven't started; that's exactly the kind of speculative scaffolding this project
deliberately avoids.

All five folders above are Xcode file-system-synchronized groups — adding a `.swift` file
under the right directory is enough; you do not need to edit `project.pbxproj` by hand.
**Exception:** `Shared/` is synchronized to *two* targets at once (Kue and KueWidget both
list it in their `fileSystemSynchronizedGroups`) — that's what makes one copy of
`ModelContainerFactory`/the `@Model` types compile into both without a shared framework.
If a file needs App-only or Widget-only imports, it does not belong in `Shared/`.

### Two targets: Kue (app) + KueWidget (extension)

Added in Phase 4. Both join the App Group `group.com.kanishkgandecha.Kue`
(`docs/03-data-model.md` "Shared storage: App Group") so `ModelContainerFactory.makeDefault()`
opens the *same* on-disk store in either process — never a copy or snapshot. The widget
extension must call `ModelContainerFactory.makeDefaultOrNil()` (not `makeDefault()`), since
a broken store there should degrade to a placeholder-style widget entry, not crash the
extension process (`docs/13-error-handling.md` "Widget refresh failure").

Both targets currently use `CODE_SIGN_STYLE = Manual` with an ad-hoc identity (`-`) — this
environment has no Apple Developer Team configured, and automatic signing silently strips
App-Group-dependent entitlements from the final signature when there's no team to validate
the capability against (confirmed empirically while building this out: the pre-strip
"-Simulated.xcent" intermediate keeps the entitlement, but automatic signing's *actual*
signed output does not, regardless of Automatic vs Manual). On a machine with a real
(even free Personal) Team signed into Xcode, switching back to Automatic should work
identically or better — do that if it becomes available rather than assuming Manual is a
permanent requirement.

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
just Phase 1.

Deployment target is iOS 26.5, set in Phase 1 — this is what backs the on-device AI
requirement above; don't lower it without updating `docs/14-open-questions.md`'s
deployment-target entry.

## Git

Git operations (commit, branch, push, etc.) in this repository are handled by the human
maintainer. Do not run `git` commands as part of implementing a feature unless
explicitly asked to.
