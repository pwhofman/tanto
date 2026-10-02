import AppKit
import KatanaKit
import SwiftUI

/// The pages below the front panel, chosen with tabs in BOSS TONE STUDIO's groups.
struct Pages: View {
    let model: EditorModel
    // `-page TITLE` opens another page, for snapshots during development (see `TantoApp`).
    @State private var selection = UserDefaults.standard.string(forKey: "page") ?? "EFFECTS"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FlowLayout(spacing: 12) {
                ForEach(model.pages.indices, id: \.self) { index in
                    let group = model.pages[index]
                    // One tab is chosen across the groups; the other groups show none.
                    TabGroup(
                        titles: group.map(\.title), selected: group.firstIndex { $0.id == selection },
                        choose: { selection = group[$0].id }
                    )
                    .fixedSize()
                }
            }
            if let page = model.pages.joined().first(where: { $0.id == selection }) {
                switch page.id {
                case "EFFECTS": EffectsPage(model: model, page: page)
                case "CHAIN": ChainPage(model: model, page: page)
                default: PageView(model: model, page: page)
                }
            }
        }
    }
}

/// A group of tabs as AppKit's segmented control, whose segments fit their titles as Tone Studio's tabs do, so that the
/// three groups fit in one row; SwiftUI's segmented picker makes every segment as wide as the widest.
private struct TabGroup: NSViewRepresentable {
    let titles: [String]
    /// The chosen tab, or `nil` if the chosen page is in another group.
    let selected: Int?
    let choose: (Int) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: titles, trackingMode: .selectOne, target: context.coordinator,
            action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fit
        control.setAccessibilityLabel("Page")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.choose = choose
        control.selectedSegment = selected ?? -1
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(choose: choose)
    }

    @MainActor
    final class Coordinator: NSObject {
        var choose: (Int) -> Void

        init(choose: @escaping (Int) -> Void) {
            self.choose = choose
        }

        @objc func changed(_ control: NSSegmentedControl) {
            if control.selectedSegment >= 0 {
                choose(control.selectedSegment)
            }
        }
    }
}

/// Tone Studio's EFFECTS page: for each effect, the variations that its GREEN, RED and YELLOW buttons select.
private struct EffectsPage: View {
    let model: EditorModel
    let page: EditorModel.Page

    // Tone Studio's columns: each effect's selected colour, and DELAY's and DELAY2's TAP under the column of their
    // assignments.
    private static let columns: [(page: String, title: String, selection: String, tap: (TapButton, left: Int)?)] = [
        ("effects-booster", "BOOSTER", "PRM_FXBOX_SEL_BOOST", nil),
        ("effects-mod", "MOD", "PRM_FXBOX_SEL_MOD", nil),
        ("effects-fx", "FX", "PRM_FXBOX_SEL_FX", nil),
        ("effects-delay", "DELAY", "PRM_FXBOX_SEL_DELAY", (.delay, 20)),
        ("effects-reverb", "REVERB", "PRM_FXBOX_SEL_REVERB", (.delay2, 118)),
    ]

    var body: some View {
        FlowLayout(spacing: 12) {
            ForEach(Self.columns, id: \.page) { column in
                EffectColumn(
                    model: model, title: column.title,
                    selection: model.map.parameter(block: "Patch_2", prm: column.selection),
                    menus: page.parameters.filter { $0.page == column.page && $0.control == .menu },
                    tap: column.tap.flatMap { button, left in
                        model.map.parameter(block: button.block, prm: "PRM_DLY_COMMON_DLY_TIME").map {
                            (button, left, $0)
                        }
                    })
            }
        }
    }
}

/// One effect's column of the EFFECTS page: a row per colour with a menu per variation. The coloured markers show the
/// colour that the effect's button has selected, and choose another, as in Tone Studio; DELAY's and DELAY2's TAP set
/// the delay time from the interval between taps.
private struct EffectColumn: View {
    let model: EditorModel
    let title: String
    let selection: Parameter?
    let menus: [Parameter]
    /// The TAP button, the column of assignments it sits under, and the DELAY TIME it sets.
    let tap: (button: TapButton, left: Int, time: Parameter)?

    // The rows, from top to bottom.
    private static let colours: [Color] = [.green, .red, .yellow]
    private static let names = ["GREEN", "RED", "YELLOW"]

    var body: some View {
        // REVERB's column also holds LAYER MODE and DELAY2, side by side.
        let lefts = Set(menus.compactMap(\.position?.x)).sorted()
        let tops = Set(menus.compactMap(\.position?.y)).sorted()
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                if lefts.count > 1 {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        ForEach(lefts, id: \.self) { left in
                            Text(heading(left)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(tops.indices, id: \.self) { row in
                    GridRow {
                        marker(row)
                        ForEach(lefts, id: \.self) { left in
                            cell(x: left, y: tops[row])
                        }
                    }
                }
                if let tap {
                    GridRow {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        ForEach(lefts, id: \.self) { left in
                            if left == tap.left {
                                tapButton(tap)
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
            }
            if let selection, let refusal = model.refusals[selection.offset] {
                Text(refusal).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    // E.g. LAYER MODE for the column of LAYER MODE GRN.
    private func heading(_ left: Int) -> String {
        let first = menus.first { $0.position?.x == left }
        return first?.label.split(separator: " ").dropLast().joined(separator: " ") ?? ""
    }

    private func marker(_ row: Int) -> some View {
        let selected = selection.flatMap(model.value(of:)) == row
        let name = Self.names[min(row, Self.names.count - 1)]
        return Button {
            if let selection {
                Task { await model.set(selection, to: row) }
            }
        } label: {
            Image(systemName: selected ? "circle.fill" : "circle")
                .foregroundStyle(Self.colours[min(row, Self.colours.count - 1)])
        }
        .buttonStyle(.borderless)
        .help("Choose \(name), as the button on the amp would")
        .accessibilityLabel(name)
        .accessibilityValue(selected ? "Selected" : "")
    }

    private func tapButton(_ tap: (button: TapButton, left: Int, time: Parameter)) -> some View {
        VStack(spacing: 4) {
            Button("TAP") { Task { await model.tap(tap.button) } }
                .help("Tap twice or more: the delay time follows the interval between taps")
            Text(model.value(of: tap.time).map(tap.time.displayText(for:)) ?? "–")
                .font(.callout).monospacedDigit()
            if let refusal = model.tapRefusals[tap.button] {
                Text(refusal).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func cell(x: Int, y: Int) -> some View {
        if let parameter = menus.first(where: { $0.position?.x == x && $0.position?.y == y }) {
            ControlView(model: model, parameter: parameter, showsLabel: false).fixedSize()
        }
    }
}

/// Tone Studio's CHAIN page: one of seven orders of the blocks, each shown as Tone Studio draws it.
private struct ChainPage: View {
    let model: EditorModel
    let page: EditorModel.Page

    // The blocks of each chain from the input onwards, from the diagrams on Tone Studio's CHAIN page.
    private static let chains = [
        ["BOOSTER", "AMP/EQ", "MOD", "FX", "DELAY", "DELAY2", "REVERB"],
        ["BOOSTER", "MOD", "AMP/EQ", "FX", "DELAY", "DELAY2", "REVERB"],
        ["BOOSTER", "MOD", "FX", "AMP/EQ", "DELAY", "DELAY2", "REVERB"],
        ["BOOSTER", "MOD", "FX", "DELAY", "AMP/EQ", "DELAY2", "REVERB"],
        ["MOD", "BOOSTER", "AMP/EQ", "FX", "DELAY", "DELAY2", "REVERB"],
        ["MOD", "BOOSTER", "FX", "AMP/EQ", "DELAY", "DELAY2", "REVERB"],
        ["MOD", "BOOSTER", "FX", "DELAY", "AMP/EQ", "DELAY2", "REVERB"],
    ]
    // Tone Studio's colours for the blocks.
    private static let tints: [String: Color] = [
        "BOOSTER": Color(red: 0.90, green: 0.57, blue: 0.07), "MOD": Color(red: 0.33, green: 0.72, blue: 0.90),
        "FX": Color(red: 0.73, green: 0.37, blue: 0.80), "DELAY": .gray, "DELAY2": .gray,
        "REVERB": Color(red: 0.12, green: 0.84, blue: 0.75),
    ]

    var body: some View {
        if let parameter = page.parameters.first {
            let value = model.value(of: parameter) ?? parameter.minimum
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    parameter.label,
                    selection: Binding(get: { value }, set: { new in Task { await model.set(parameter, to: new) } })
                ) {
                    ForEach(parameter.options ?? [], id: \.value) { option in
                        HStack(spacing: 6) {
                            Text(option.label).monospaced().frame(width: 80, alignment: .leading)
                            ForEach(Self.chains[option.value], id: \.self) { block in
                                Text(block)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background((Self.tints[block] ?? .secondary).opacity(0.3), in: Capsule())
                            }
                        }
                        .tag(option.value)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if let refusal = model.refusals[parameter.offset] {
                    Text(refusal).font(.caption2).foregroundStyle(.red)
                }
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
            model.position(of: parameter).map { Placed(parameter: parameter, x: $0.x, y: $0.y) }
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
                    // The switch in Tone Studio's title bar turns the page's block on and off; its title stands beside it.
                    if item.y < 0, item.parameter.control == .switch {
                        HStack(spacing: 8) {
                            ControlView(model: model, parameter: item.parameter, showsLabel: false)
                            Text(page.title).font(.headline)
                        }
                        .fixedSize()
                    } else {
                        ControlView(model: model, parameter: item.parameter).fixedSize()
                    }
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

    // With the row's spacing, a knob takes Tone Studio's step between dials (96 px) and a slider its step between bands
    // (48 px); labels wrap inside.
    @ViewBuilder
    private func cell(_ parameter: Parameter) -> some View {
        switch parameter.control {
        case .knob: ControlView(model: model, parameter: parameter).frame(width: 88)
        case .slider: ControlView(model: model, parameter: parameter).frame(width: 40)
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
