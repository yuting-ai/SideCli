//
//  PaneGlyph.swift
//  SideCli
//
//  Line icons for pane actions, drawn on a 16×16 grid so the toolbar and the
//  pane header use exactly the same shapes:
//    splitVertical   — tall box with a horizontal line (日): top / bottom
//    splitHorizontal — wide box with a vertical line: left | right
//    zoom            — outward diagonal arrows
//    equalize        — two arrows pointing at a centre line
//

import SwiftUI
import Combine

enum PaneGlyphKind {
    case splitVertical
    case splitHorizontal
    case zoom
    case equalize
}

struct PaneGlyphShape: Shape {
    let kind: PaneGlyphKind

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        let ox = rect.midX - 8 * s, oy = rect.midY - 8 * s
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        func line(_ p: inout Path, _ points: [(CGFloat, CGFloat)]) {
            guard let first = points.first else { return }
            p.move(to: pt(first.0, first.1))
            for point in points.dropFirst() { p.addLine(to: pt(point.0, point.1)) }
        }

        var p = Path()
        switch kind {
        case .splitVertical:
            p.addRoundedRect(in: CGRect(origin: pt(3, 1.5), size: CGSize(width: 10 * s, height: 13 * s)),
                             cornerSize: CGSize(width: 1.6 * s, height: 1.6 * s))
            line(&p, [(3, 8), (13, 8)])
        case .splitHorizontal:
            p.addRoundedRect(in: CGRect(origin: pt(1.5, 3), size: CGSize(width: 13 * s, height: 10 * s)),
                             cornerSize: CGSize(width: 1.6 * s, height: 1.6 * s))
            line(&p, [(8, 3), (8, 13)])
        case .zoom:
            line(&p, [(9.5, 2.5), (13.5, 2.5), (13.5, 6.5)])
            line(&p, [(6.5, 13.5), (2.5, 13.5), (2.5, 9.5)])
            line(&p, [(13.5, 2.5), (9, 7)])
            line(&p, [(2.5, 13.5), (7, 9)])
        case .equalize:
            line(&p, [(8, 2.5), (8, 13.5)])
            line(&p, [(1.5, 8), (6, 8)])
            line(&p, [(4.5, 6), (6.5, 8), (4.5, 10)])
            line(&p, [(14.5, 8), (10, 8)])
            line(&p, [(11.5, 6), (9.5, 8), (11.5, 10)])
        }
        return p
    }
}

struct PaneGlyph: View {
    let kind: PaneGlyphKind
    var size: CGFloat = 15

    var body: some View {
        PaneGlyphShape(kind: kind)
            .stroke(style: StrokeStyle(lineWidth: max(1.1, size / 16 * 1.4), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}
