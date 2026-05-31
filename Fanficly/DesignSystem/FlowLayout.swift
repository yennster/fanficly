import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let totalHeight = rows.reduce(CGFloat.zero) { $0 + $1.height } +
            CGFloat(max(0, rows.count - 1)) * lineSpacing
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: widest, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = row.sizes[index - row.indices.lowerBound]
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: Range<Int>
        var sizes: [CGSize]
        var width: CGFloat
        var height: CGFloat
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var lineStart = 0
        var lineSizes: [CGSize] = []
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthIfAdded = lineWidth + (lineSizes.isEmpty ? 0 : spacing) + size.width
            if widthIfAdded > maxWidth, !lineSizes.isEmpty {
                rows.append(Row(
                    indices: lineStart..<index,
                    sizes: lineSizes,
                    width: lineWidth,
                    height: lineHeight
                ))
                lineStart = index
                lineSizes = [size]
                lineWidth = size.width
                lineHeight = size.height
            } else {
                if !lineSizes.isEmpty { lineWidth += spacing }
                lineWidth += size.width
                lineHeight = max(lineHeight, size.height)
                lineSizes.append(size)
            }
        }
        if !lineSizes.isEmpty {
            rows.append(Row(
                indices: lineStart..<subviews.endIndex,
                sizes: lineSizes,
                width: lineWidth,
                height: lineHeight
            ))
        }
        return rows
    }
}
