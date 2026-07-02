//
//  ScrollFade.swift
//  RunRightApp
//
//  Reusable header "fade on scroll" used by every tab. Drop a ScrollOffsetReader
//  at the top of the scroll content, name the scroll's coordinate space, then
//  apply scrollFadeOpacity(offset) to the header.

import SwiftUI

/// Reports the scroll content's top offset (minY) in a named coordinate space.
struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Place as the first child of scroll content to publish its offset.
struct ScrollOffsetReader: View {
    let space: String
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ScrollOffsetKey.self,
                value: geo.frame(in: .named(space)).minY
            )
        }
        .frame(height: 0)
    }
}

/// Header opacity from scroll offset: fully visible at top, gone by `distance` pt down.
func scrollFadeOpacity(_ offset: CGFloat, distance: CGFloat = 60) -> Double {
    Double(max(0, min(1, 1 + offset / distance)))
}
