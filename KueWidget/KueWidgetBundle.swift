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
    }
}
