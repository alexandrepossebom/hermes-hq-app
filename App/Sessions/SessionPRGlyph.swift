import UIKit

/// Tiny git graphs. Shape, not just color, distinguishes each state.
@MainActor enum SessionPRGlyph {
    static func color(_ state: SessionPRStatus.State) -> UIColor {
        switch state {
        case .open: .systemGreen
        case .merged: .systemPurple
        case .closed: .systemRed
        case .none, .draft, .unknown: HQPalette.label2
        }
    }

    private static var cache: [SessionPRStatus.State: UIImage] = [:]
    static func image(_ state: SessionPRStatus.State) -> UIImage {
        if let image = cache[state] { return image }
        let size = CGSize(width: 16, height: 16)
        let image = UIGraphicsImageRenderer(size: size).image { renderer in
            let c = renderer.cgContext
            c.setStrokeColor(UIColor.black.cgColor); c.setFillColor(UIColor.black.cgColor)
            c.setLineWidth(1.55); c.setLineCap(.round); c.setLineJoin(.round)
            func line(_ points: CGPoint...) {
                guard let first = points.first else { return }; c.move(to: first)
                for p in points.dropFirst() { c.addLine(to: p) }; c.strokePath()
            }
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
            func node(_ x: CGFloat, _ y: CGFloat) { c.strokeEllipse(in: CGRect(x: x-1.7, y: y-1.7, width: 3.4, height: 3.4)) }
            if state == .unknown {
                c.strokeEllipse(in: CGRect(x: 1.5, y: 1.5, width: 13, height: 13))
                c.move(to: p(5.9, 6.2)); c.addCurve(to: p(9.8, 6.6), control1: p(6.2, 3.8), control2: p(10.8, 4.2)); c.addQuadCurve(to: p(8, 9), control: p(8, 8)); c.strokePath()
                c.fillEllipse(in: CGRect(x: 7.2, y: 10.6, width: 1.6, height: 1.6)); return
            }
            node(3.5, 3); node(3.5, 13); line(p(3.5, 5), p(3.5, 11))
            switch state {
            case .none, .merged:
                let flipped = state == .merged
                node(12, flipped ? 13 : 3)
                c.move(to: p(12, flipped ? 11 : 5)); c.addQuadCurve(to: p(3.8, 8), control: p(12, 8)); c.strokePath()
                if flipped { line(p(6.4, 5.6), p(3.8, 8), p(6.4, 10.4)) }
            case .open, .draft, .closed:
                node(12, 13)
                if state == .closed {
                    line(p(9.4, 2.2), p(13.4, 6.2)); line(p(13.4, 2.2), p(9.4, 6.2)); line(p(12, 8.8), p(12, 11))
                } else {
                    if state == .draft { c.setLineDash(phase: 0, lengths: [1, 2.4]) }
                    c.move(to: p(12, 11)); c.addLine(to: p(12, 6)); c.addQuadCurve(to: p(9, 3.5), control: p(12, 3.5)); c.strokePath()
                    c.setLineDash(phase: 0, lengths: []); line(p(9.5, 1.5), p(7.5, 3.5), p(9.5, 5.5))
                }
            case .unknown: break
            }
        }.withRenderingMode(.alwaysTemplate)
        cache[state] = image
        return image
    }
}
