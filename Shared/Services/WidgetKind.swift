//
//  WidgetKind.swift
//  Kue
//
//  The widget `kind` string, shared so the app side (WidgetCenter.reloadTimelines(ofKind:))
//  and the extension side (Widget's own `kind`) can never drift apart into two different
//  literals — see docs/07-widget-engine.md "Refresh strategy".
//

enum WidgetKind {
    static let kue = "KueWidget"
    /// Kue 2.0 Phase 8 — see docs/22-expanded-and-dedicated-widgets.md "A." A genuinely
    /// separate widget kind, not a mode of `kue` above, so its own `AppIntentConfiguration`
    /// carries an independent per-instance selection that can never fall back to "Next Up".
    static let dedicatedCountdown = "KueDedicatedCountdownWidget"
}
