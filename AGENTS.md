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
Kue/
  KueApp.swift              App entry point — builds the ModelContainer, sets HomeView as root
  Models/                   @Model classes + their Codable/enum types, one file per model
  Persistence/              ModelContainerFactory — the single place the SwiftData schema
                             and ModelContainer are constructed (production + in-memory)
  Features/<Screen>/        One SwiftUI view (+ its own small subviews) per screen
KueTests/                   Swift Testing (`import Testing`) unit tests
KueUITests/                 XCTest UI tests (unchanged template scaffolding so far)
```

`Services/` (event engine, scheduling engine, notification engine, AI parser) and a
`Utilities/` folder don't exist yet — they'll appear when the phase that needs them
starts (Phase 2 for the event engine, Phase 3 for scheduling, etc.). Don't pre-create
empty folders or placeholder types for subsystems that haven't started; that's exactly
the kind of speculative scaffolding this project deliberately avoids.

Both `Kue/` (main target), `KueTests/`, and `KueUITests/` are Xcode file-system-synchronized
groups — adding a `.swift` file under the right directory is enough; you do not need to
edit `project.pbxproj` by hand.

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
