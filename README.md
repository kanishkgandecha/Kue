# Kue 2.0

A privacy-focused native iOS application for planning, tracking, and remembering important events.

Kue combines event countdowns, tasks, recurring schedules, reminders, widgets, Live Activities, Calendar integration, OCR, voice input, Siri, Shortcuts, and Spotlight in one SwiftUI application.

> Kue 2.0 is currently a personal-device project and is not published on the App Store.

## Overview

Important events are usually spread across calendars, reminder apps, screenshots, notes, and countdown widgets. Kue brings these workflows together while keeping the event—not a generic task list—at the center of the experience.

Kue can be used for:

- Exams and application deadlines
- Trips and reservations
- Birthdays and anniversaries
- Appointments and meetings
- Project milestones
- Personal goals and scheduled activities

Each event can contain dates, preparation tasks, notifications, recurrence rules, Calendar links, widgets, and an explicit outcome.

## Highlights

- Native SwiftUI interface with light and dark appearances
- Date-grouped event timeline
- Event search, filtering, sorting, and duplication
- Reusable event templates and schedules
- Recurring events with occurrence-level editing
- Home Screen and Lock Screen widgets
- Dedicated widget for one explicitly selected event
- Live Activities and Dynamic Island support
- Apple Calendar import and export
- Screenshot and photo recognition using Vision OCR
- On-device voice input
- Siri, Shortcuts, Spotlight, and Control Center integrations
- Reliable reminders and actionable notifications
- Versioned backups and non-destructive restoration
- Hardened migration from Kue 1.0
- CloudKit-ready multi-device synchronization architecture
- CloudKit-free Personal build configuration

## Event Lifecycle

Kue does not silently mark an event as completed when its time passes.

A past event without an explicit result enters **Needs Review**. The user can then choose to:

- Mark it completed
- Reschedule it
- Skip it
- Cancel it

This prevents missed events from being misrepresented as successfully completed.

## Recurring Events

Recurring events support:

- Daily, weekly, monthly, and yearly recurrence
- Custom recurrence rules
- Individual occurrence exceptions
- Editing only one occurrence
- Editing an occurrence and all future occurrences
- Safe reconciliation when a recurring series changes

A SwiftData detached-fault crash in the “This and Future Occurrences” workflow was diagnosed and fixed by resolving stored values before deletion and performing post-save reconciliation through a fresh `ModelContext`.

## Widgets

Kue includes two widget experiences.

### Next-Up Widget

Automatically presents the next eligible event.

Supported families include:

- Small
- Medium
- Large
- Lock Screen circular
- Lock Screen rectangular
- Lock Screen inline

### Dedicated Countdown

Remains attached to one event explicitly selected by the user.

Unlike the automatic widget, it never silently switches to another event. When the selected event is finished or unavailable, the widget asks the user to choose a replacement.

## Live Activities and Focus Mode

An event can be explicitly placed into Focus Mode.

Kue supports:

- Lock Screen Live Activities
- Dynamic Island minimal presentation
- Dynamic Island compact presentation
- Dynamic Island expanded presentation
- Task and event actions
- Confirmation before replacing the active event
- Privacy controls for displayed titles and tasks

Only one event can be focused at a time, and Kue never selects one automatically.

## Calendar Integration

Calendar support is implemented through a protocol-based EventKit abstraction.

Capabilities include:

- Importing Apple Calendar events
- Exporting Kue events
- Updating linked events
- Detecting missing external events
- Detecting external modifications and conflicts
- Preserving external identifiers and synchronization metadata

System and in-memory fake providers keep application logic independently testable.

## Screenshot and OCR Input

Kue can extract event information from screenshots and photos using Vision.

The image pipeline includes:

- JPEG, PNG, and HEIC validation
- Encoded-size limits
- Dimension and pixel-count limits
- Bounded downsampling
- EXIF orientation correction
- In-memory processing
- No persistence of recognized source text

Recognized information is presented for review before an event is saved.

## Voice Input

Voice input uses Apple Speech and AVFoundation behind testable abstractions.

The voice workflow provides:

- On-device recognition enforcement
- Live partial transcripts
- Final transcript review
- A 60-second recording limit
- A five-second silence timeout
- Microphone and speech-permission handling
- Audio-session cleanup
- Protection from late callbacks belonging to cancelled sessions
- No temporary audio files

## Siri, Shortcuts, Spotlight and Controls

Kue integrates with Apple system surfaces through App Intents and Core Spotlight.

Supported capabilities include:

- Creating events
- Finding events
- Completing, skipping, cancelling, and rescheduling events
- Opening specific application destinations
- Spotlight event indexing
- Quick Add Control
- Show Next Event Control
- Complete Next Task Control
- Stop Focus Control

Mutation intents reuse the same application services as the main interface rather than duplicating business logic.

## Notifications

Kue supports:

- Configurable pre-event reminders
- Starting-now notifications
- Outcome follow-up notifications
- Mark Completed actions
- Reschedule actions
- Skip actions
- Cancel actions

Event Detail shows the actual state of each reminder, including whether it is scheduled, passed, disabled, or potentially affected by the system notification limit.

## Backup and Restore

Kue exports a versioned `.kuebackup` file.

The backup format provides:

- Versioned JSON envelopes
- Checksum validation
- Validation before SwiftData deserialization
- Merge-by-UUID restoration
- Conflict handling
- Non-destructive restore behavior
- Rejection of tampered or unsupported backups

Restoring a backup does not erase the existing database.

## Legacy Migration Safety

Kue 2.0 successfully migrated real Kue 1.0 data on an iPhone while preserving existing events.

The migration system includes:

- Versioned SwiftData schemas
- Explicit migration stages
- Exact legacy-store metadata verification
- Fail-closed recovery eligibility
- SQLite Online Backup API snapshots
- Automatic restoration after failed recovery
- Relationship validation
- Post-migration write validation
- Independent close-and-reopen validation

Unknown, corrupted, future, and already-migrated stores are not silently treated as legacy Kue 1.0 stores.

## Personal and Cloud Builds

Kue contains two build configurations.

### Kue

The CloudKit-capable application configuration.

### Kue Personal

A personal-device build designed for installation without paid CloudKit capabilities.

The Personal build:

- Contains no CloudKit entitlement
- Prevents `CKContainer` construction at compile time
- Uses local persistence
- Supports `.kuebackup` export and restoration
- Clearly explains its synchronization limitations

No custom Kue account is required.

## Architecture

Kue uses a native, service-oriented architecture.

```text
Kue
├── App and navigation
├── SwiftUI feature views
├── Domain and orchestration services
├── SwiftData persistence
├── Versioned migrations
├── App Intents and deep links
├── Widget extension
├── Share extension
├── Live Activities
└── Unit and UI tests
