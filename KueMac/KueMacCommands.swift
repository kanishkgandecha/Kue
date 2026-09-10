//
//  KueMacCommands.swift
//  KueMac
//
//  Kue 3.0 Phase 1 — native Mac menu commands. Every mutating command routes through
//  `MacAppState.pendingCommand`, which `RootSplitView` observes and acts on — no duplicated
//  mutation logic here, this file only decides *which* action the menu asked for and whether
//  it's currently available (disabled, not hidden, when it isn't — requirement: "Menu commands
//  must disable themselves when their action is unavailable").
//

import SwiftUI

struct KueMacCommands: Commands {
    @Bindable var appState: MacAppState
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Event") { appState.pendingCommand = .newEvent }
                .keyboardShortcut("n", modifiers: .command)
            Button("Import from Calendar…") { appState.pendingCommand = .importFromCalendar }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Home") { appState.pendingCommand = .showHome }
                .keyboardShortcut("1", modifiers: .command)
            Button("Today") { appState.pendingCommand = .showToday }
                .keyboardShortcut("2", modifiers: .command)
            Button("Upcoming") { appState.pendingCommand = .showUpcoming }
                .keyboardShortcut("3", modifiers: .command)
            Button("Needs Review") { appState.pendingCommand = .showNeedsReview }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Search") { appState.pendingCommand = .search }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Delete Event", role: .destructive) {
                appState.pendingCommand = .deleteSelectedEvent
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!appState.hasSelection)
        }
        CommandMenu("Backup") {
            Button("Export Backup…") { openSettings() }
            Button("Restore Backup…") { openSettings() }
        }
    }
}
