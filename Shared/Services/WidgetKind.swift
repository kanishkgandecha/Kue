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
}
