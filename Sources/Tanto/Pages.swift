import KatanaKit
import SwiftUI

/// The pages below the front panel, chosen with tabs in BOSS TONE STUDIO's groups.
struct Pages: View {
    let model: EditorModel
    // `-page TITLE` opens another page, for snapshots during development (see `TantoApp`).
    @State private var selection = UserDefaults.standard.string(forKey: "page") ?? "BOOSTER"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FlowLayout(spacing: 12) {
                ForEach(model.pages.indices, id: \.self) { index in
                    let group = model.pages[index]
                    // One tab is chosen across the groups; the other groups show none.
                    Picker(
                        "Page",
                        selection: Binding<String?>(
                            get: { group.contains { $0.id == selection } ? selection : nil },
                            set: { if let new = $0 { selection = new } })
                    ) {
                        ForEach(group) { page in
                            Text(page.title).tag(Optional(page.id))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if let page = model.pages.joined().first(where: { $0.id == selection }) {
                PageView(model: model, page: page)
            }
        }
    }
}

/// One page as Tone Studio lays it out: the on/off switch and the type menus in a header row, then the other controls in
/// Tone Studio's rows, each at Tone Studio's horizontal position while the row fits the window. Controls that the
/// current effect type does not use are left out.
private struct PageView: View {
    let model: EditorModel
    let page: EditorModel.Page

    /// A control and where Tone Studio puts it.
    private struct Placed {
        let parameter: Parameter
        let x: Int
        let y: Int
    }

    // Tone Studio's rows of dials start at a top of 60 or more; above them are the switch and the menus.
    private static let headerBottom = 60
    // Controls whose tops are closer than this share a row.
    private static let rowGap = 30

    var body: some View {
        let placed = page.parameters.filter(model.isVisible).compactMap { parameter in
            parameter.position.map { Placed(parameter: parameter, x: $0.x, y: $0.y) }
        }
        let header = placed.filter { $0.y < Self.headerBottom }.sorted { $0.x < $1.x }
        let rows = Self.rows(placed.filter { $0.y >= Self.headerBottom })
        let left = rows.joined().map(\.x).min() ?? 0
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                // Tone Studio's CONTOUR page starts with the front panel's CONTOUR knob.
                if page.id == "CONTOUR" {
                    ContourKnob(model: model).fixedSize()
                }
                ForEach(header, id: \.parameter.offset) { item in
                    ControlView(model: model, parameter: item.parameter).fixedSize()
                }
            }
            ForEach(rows.indices, id: \.self) { index in
                PositionedRow(lefts: rows[index].map { CGFloat($0.x - left) }) {
                    ForEach(rows[index], id: \.parameter.offset) { item in
                        cell(item.parameter)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // A knob is as wide as Tone Studio's step between dials, a slider as its step between bands; labels wrap inside.
    @ViewBuilder
    private func cell(_ parameter: Parameter) -> some View {
        switch parameter.control {
        case .knob: ControlView(model: model, parameter: parameter).frame(width: 88)
        case .slider: ControlView(model: model, parameter: parameter).frame(width: 44)
        default: ControlView(model: model, parameter: parameter).fixedSize()
        }
    }

    // The controls in rows by their tops, each row ordered by left.
    private static func rows(_ placed: [Placed]) -> [[Placed]] {
        var rows: [[Placed]] = []
        for item in placed.sorted(by: { ($0.y, $0.x) < ($1.y, $1.x) }) {
            if let top = rows.last?.first?.y, item.y - top < rowGap {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { $0.sorted { $0.x < $1.x } }
    }
}

/// Places its views at the given horizontal positions, top-aligned. A view that would overlap the one before it moves
/// right, and one that would pass the right edge starts a new line, which keeps the gaps between the positions.
private struct PositionedRow: Layout {
    let lefts: [CGFloat]
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        // A new line starts at the position of its first view.
        var shift: CGFloat = 0
        var top: CGFloat = 0
        var lineHeight: CGFloat = 0
        var next: CGFloat = 0
        for (subview, left) in zip(subviews, lefts) {
            let size = subview.sizeThatFits(.unspecified)
            var x = max(left - shift, next)
            if x > 0, x + size.width > width {
                top += lineHeight + spacing
                lineHeight = 0
                shift = left
                x = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: top), size: size))
            next = x + size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}
