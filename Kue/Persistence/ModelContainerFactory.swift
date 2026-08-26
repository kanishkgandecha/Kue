//
//  ModelContainerFactory.swift
//  Kue
//
//  Centralizes the SwiftData schema/ModelContainer so the app, previews, and tests build it
//  the same way. Phase 4 will point makeDefault()'s ModelConfiguration at an App Group
//  container URL (docs/03-data-model.md "Shared storage: App Group") without changing any
//  call site — that's the point of having exactly one place this is built. Not configured yet
//  per this phase's scope.
//

import SwiftData

enum ModelContainerFactory {
    /// Every `@Model` type Kue persists in V1.
    static let schema = Schema([
        KueEvent.self,
        KueTask.self,
        KueSchedule.self,
        WidgetConfiguration.self,
        WidgetState.self,
        Template.self,
        UserPreference.self,
    ])

    /// The app's real, on-disk store.
    static func makeDefault() -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    /// Ephemeral store for unit tests and SwiftUI previews — never touches disk.
    static func makeInMemory() -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create in-memory ModelContainer: \(error)")
        }
    }
}
