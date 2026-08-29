//
//  KueWidgetBundle.swift
//  KueWidget
//

import WidgetKit
import SwiftUI

@main
struct KueWidgetBundle: WidgetBundle {
    var body: some Widget {
        KueWidget()
        // Kue 2.0 Phase 8 — see docs/22-expanded-and-dedicated-widgets.md.
        DedicatedCountdownWidget()
        // Kue 2.0 Phase 9 — see docs/23-live-activities-and-focus-mode.md.
        KueLiveActivityWidget()
        // Kue 2.0 Phase 10 — see docs/24-siri-shortcuts-spotlight-and-controls.md "H."
        // `ControlWidget`s are auto-adapted into `Widget`s by `WidgetBundleBuilder` itself —
        // no separate `ControlWidgetBundle`/`@main` needed.
        QuickAddControl()
        ShowNextEventControl()
        CompleteNextTaskControl()
        StopFocusControl()
    }
}
