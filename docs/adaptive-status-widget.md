# Adaptive Status

One WidgetKit configuration with small and medium Home Screen layouts and a rectangular Lock Screen layout. Add it from the xDrip widget gallery by selecting **Adaptive Status**.

It reads the same app-group snapshot as the existing widgets. Each app update reloads all widget timelines. Missing or invalid data shows “No data”; no sample values are used outside previews. Readings become stale after the existing seven-minute deadline and disappear after twenty minutes. WidgetKit controls actual refresh delivery.

The user's urgent limits determine red/critical status; regular low/high limits determine yellow status. Within range, a linear 15-minute trend estimate from the last two valid readings may produce yellow when approaching either regular limit. Prediction is skipped for duplicate timestamps, intervals under one minute or gaps over ten minutes. It is a visual hint only and never changes readings, alerts or treatment logic.

On iOS 26, full-color layouts use SwiftUI Liquid Glass with progressively stronger tint for normal, warning and critical states. Earlier supported systems use ultra-thin material; Reduce Transparency uses an opaque surface. The Lock Screen and tinted Home Screen apply WidgetKit's system rendering, so exact red/yellow/green colors and wallpaper refraction cannot be guaranteed. Status text and prominence remain meaningful without color. The reference artwork's large full-width Lock Screen panel is adapted to the system's rectangular accessory slot.

Validation: `AdaptiveGlucoseStatusTests` covers threshold boundaries, both trend directions, stale data, sensor errors, missing readings and invalid timestamp gaps. Xcode 26.2 is selected by the existing workflows. Compilation, XCTest and real-device visual verification require macOS/iPhone.
