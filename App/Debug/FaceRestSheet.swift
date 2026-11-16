// DEBUG: every kind of face as it rests, beside words as in a list, on one sheet: to check that each keeps to the
// right, looking at the text (owner, 2026-11-16). FaceRestSheetTests writes both pages when a test run sets
// `TEST_RUNNER_HQ_FACE_REST=<folder>`.

#if DEBUG
import UIKit

enum FaceRestSheet {
    static let names = FaceMoodsDemo.names
    static let kinds: [(title: String, theme: String?)] = [("Shapes (every bot's own)", "own"), ("Blob", "blob"), ("Dot-matrix", nil),
                                                            ("Robot", "robot"), ("Dots", "dots"), ("Orb", "orb"), ("Pixel", "pixel")]

    static func head(_ index: Int, theme: String?) -> Head {
        theme == "own" ? Head.resolve(nil, profile: names[index % names.count]) : FaceMoodsDemo.head(index, theme: theme)
    }

    static func render(dark: Bool) -> UIImage {
        let columns = 4, cell = CGSize(width: 270, height: 58), margin: CGFloat = 28, big: CGFloat = 96
        let perKind = 8, rows = perKind / columns
        let block = 34 + big + 16 + CGFloat(rows) * cell.height + 22
        let size = CGSize(width: margin * 2 + CGFloat(columns) * cell.width, height: margin + CGFloat(kinds.count) * block)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let page: UIColor = dark ? .black : .white, ink: UIColor = dark ? .white : .black
        let soft = UIColor(white: dark ? 0.6 : 0.42, alpha: 1)
        func picture(_ head: Head, _ side: CGFloat) -> UIImage? {
            HeadRenderer.picture(head, side: side, scale: 2, dark: dark).map { UIImage(cgImage: $0, scale: 2, orientation: .up) }
        }
        func text(_ string: String, _ at: CGPoint, _ size: CGFloat, _ weight: UIFont.Weight, _ color: UIColor) {
            NSAttributedString(string: string, attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: at)
        }
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            page.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            var y = margin
            for kind in kinds {
                text(kind.title.uppercased(), CGPoint(x: margin, y: y), 13, .semibold, soft)
                y += 34
                for index in 0..<6 {
                    picture(head(index, theme: kind.theme), big)?.draw(in: CGRect(x: margin + CGFloat(index) * (big + 28), y: y, width: big, height: big))
                }
                y += big + 16
                for index in 0..<perKind {
                    let x = margin + CGFloat(index % columns) * cell.width, top = y + CGFloat(index / columns) * cell.height
                    picture(head(index, theme: kind.theme), 40)?.draw(in: CGRect(x: x, y: top + 6, width: 40, height: 40))
                    text(names[index % names.count].capitalized, CGPoint(x: x + 52, y: top + 7), 16, .semibold, ink)
                    text("Sent the weekly numbers over", CGPoint(x: x + 52, y: top + 28), 13, .regular, soft)
                }
                y += CGFloat(rows) * cell.height + 22
            }
        }
    }
}
#endif
