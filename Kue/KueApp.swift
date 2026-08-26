//
//  KueApp.swift
//  Kue
//
//  Created by Kanishk Gandecha on 25/08/26.
//

import SwiftUI
import SwiftData

@main
struct KueApp: App {
    let modelContainer: ModelContainer = ModelContainerFactory.makeDefault()

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .modelContainer(modelContainer)
    }
}
