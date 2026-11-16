import UIKit

#if DEBUG
/// A separately baselined observation window. A missing baseline cannot become valid just because rows appear later.
@MainActor
struct ActivityMotionPhaseWindow {
    struct Track {
        let base: CGRect
        let baseInset: CGFloat
        let baseShelfExtent: CGFloat
        var last: CGRect
        var travel: CGFloat = 0
        var step: CGFloat = 0
        var pathLength: CGFloat = 0
        var height: CGFloat = 0
        var horizontal: CGFloat = 0
        var width: CGFloat = 0
        var anchorError: CGFloat = 0
        var insetShelfError: CGFloat = 0
        var moves = 0
        var direction: CGFloat = 0
        var reversals = 0

        init(_ rect: CGRect, inset: CGFloat, shelfExtent: CGFloat) {
            base = rect
            last = rect
            baseInset = inset
            baseShelfExtent = shelfExtent
        }

        mutating func sample(_ rect: CGRect, inset: CGFloat, shelfExtent: CGFloat) {
            let delta = rect.minY - last.minY
            travel = max(travel, abs(rect.minY - base.minY))
            step = max(step, abs(delta))
            pathLength += abs(delta)
            height = max(height, abs(rect.height - base.height))
            horizontal = max(horizontal, abs(rect.minX - base.minX))
            width = max(width, abs(rect.width - base.width))
            // The flipped table's newest-end inset grows upward on screen.
            anchorError = max(anchorError, abs((rect.minY - base.minY) + (inset - baseInset)))
            insetShelfError = max(insetShelfError, abs((inset - baseInset) - (shelfExtent - baseShelfExtent)))
            if abs(delta) > 0.3 {
                moves += 1
                let sign: CGFloat = delta > 0 ? 1 : -1
                if direction != 0 && sign != direction { reversals += 1 }
                direction = sign
            }
            last = rect
        }
    }

    private(set) var tracks: [String: Track] = [:]
    private(set) var baselineIDs: Set<String> = []
    private(set) var matchedBaselineIDs: Set<String> = []
    private(set) var frames = 0
    private(set) var coveredFrames = 0
    private(set) var uncoveredFrames = 0

    private(set) var incompleteCoverageFrames = 0
    // contentInset is model-only; remove the not-yet-rendered scroll-bounds adjustment.
    static func renderedInset(modelInset: CGFloat, modelOffset: CGFloat, presentationOffset: CGFloat) -> CGFloat {
        modelInset + modelOffset - presentationOffset
    }

    mutating func reset(rows: [String: CGRect], inset: CGFloat = 0, shelfExtent: CGFloat = 0) {
        tracks = rows.mapValues { Track($0, inset: inset, shelfExtent: shelfExtent) }
        baselineIDs = Set(rows.keys)
        matchedBaselineIDs = []
        frames = 0
        coveredFrames = 0
        uncoveredFrames = 0
        incompleteCoverageFrames = 0
    }

    mutating func sample(rows: [String: CGRect], inset: CGFloat = 0, shelfExtent: CGFloat = 0) {
        frames += 1
        matchedBaselineIDs = baselineIDs.intersection(rows.keys)
        if matchedBaselineIDs.isEmpty { uncoveredFrames += 1 } else { coveredFrames += 1 }
        if baselineIDs.isEmpty || matchedBaselineIDs != baselineIDs { incompleteCoverageFrames += 1 }
        for (id, rect) in rows {
            guard var track = tracks[id] else {
                tracks[id] = Track(rect, inset: inset, shelfExtent: shelfExtent)
                continue
            }
            track.sample(rect, inset: inset, shelfExtent: shelfExtent)
            tracks[id] = track
        }
    }

    var still: CGFloat { tracks.values.map(\.travel).max() ?? 0 }
    var step: CGFloat { tracks.values.map(\.step).max() ?? 0 }
    var excessMotion: CGFloat { tracks.values.map { $0.pathLength - $0.step }.max() ?? 0 }
    var height: CGFloat { tracks.values.map(\.height).max() ?? 0 }
    var horizontal: CGFloat { tracks.values.map(\.horizontal).max() ?? 0 }
    var width: CGFloat { tracks.values.map(\.width).max() ?? 0 }
    var anchorError: CGFloat { tracks.values.map(\.anchorError).max() ?? 0 }
    var insetShelfError: CGFloat { tracks.values.map(\.insetShelfError).max() ?? 0 }
    var moves: Int { tracks.values.map(\.moves).max() ?? 0 }
    var reversals: Int { tracks.values.map(\.reversals).max() ?? 0 }
}

/// Compare the shelf/header against their own committed model states, in chat coordinates.
struct ActivityShelfPresentationCheck {
    /// A zero model height is not absence while an outgoing surface is still presented.
    static func needsSampling(model: CALayer, presentation: CALayer?, headerPresentation: CALayer?) -> Bool {
        if model.bounds.height > 0.5 { return true }
        return [presentation, headerPresentation].compactMap { $0 }.contains {
            !$0.isHidden && $0.opacity > 0 && !$0.bounds.isEmpty
        }
    }
    let model: CGRect
    let presentation: CGRect
    let modelOpacity: CGFloat
    let presentationOpacity: CGFloat
    var modelTransform: CATransform3D = CATransform3DIdentity
    var presentationTransform: CATransform3D = CATransform3DIdentity
    var geometryError: CGFloat {
        max(abs(model.minX - presentation.minX), abs(model.minY - presentation.minY),
            abs(model.width - presentation.width), abs(model.height - presentation.height))
    }
    var opacityError: CGFloat { abs(modelOpacity - presentationOpacity) }
    var transformError: CGFloat {
        let a = modelTransform, b = presentationTransform
        return [abs(a.m11-b.m11), abs(a.m12-b.m12), abs(a.m13-b.m13), abs(a.m14-b.m14),
                abs(a.m21-b.m21), abs(a.m22-b.m22), abs(a.m23-b.m23), abs(a.m24-b.m24),
                abs(a.m31-b.m31), abs(a.m32-b.m32), abs(a.m33-b.m33), abs(a.m34-b.m34),
                abs(a.m41-b.m41), abs(a.m42-b.m42), abs(a.m43-b.m43), abs(a.m44-b.m44)].max() ?? 0
    }
    private var matchesModel: Bool { geometryError <= 1 && opacityError <= 0.01 && transformError <= 0.001 }
    func alignedWithPreviousModel(_ previous: Self?) -> Self {
        guard !matchesModel, let previous else { return self }
        // A display-link sample can see the next model before its transaction is presented.
        // Accept the immediately preceding complete model, never an interpolated state.
        let prior = Self(model: previous.model, presentation: presentation,
                         modelOpacity: previous.modelOpacity, presentationOpacity: presentationOpacity,
                         modelTransform: previous.modelTransform, presentationTransform: presentationTransform)
        return prior.matchesModel ? prior : self
    }
    static func capture(model: CALayer, chat: CALayer, presentation: CALayer, presentationChat: CALayer) -> Self {
        Self(model: model.convert(model.bounds, to: chat),
             presentation: presentation.convert(presentation.bounds, to: presentationChat),
             modelOpacity: CGFloat(model.opacity), presentationOpacity: CGFloat(presentation.opacity),
             modelTransform: model.transform, presentationTransform: presentation.transform)
    }
}

struct ActivityShelfVisibilityCheck {
    let expected: CGRect
    let actual: CGRect
    let chat: CGRect
    let viewportInChat: CGRect
    let attached: Bool
    let opacity: CGFloat
    var withinChat: Bool {
        let geometry = ActivityShelfPresentationCheck(model: expected, presentation: actual, modelOpacity: 1, presentationOpacity: 1)
        return attached && opacity > 0.99 && !actual.isEmpty && chat.insetBy(dx: -1, dy: -1).contains(actual)
            && geometry.geometryError <= 1
    }
    var eligible: Bool { !expected.intersection(viewportInChat).isEmpty }
    var visibleWhenEligible: Bool {
        guard eligible, withinChat else { return false }
        let needed = expected.intersection(viewportInChat)
        let visible = actual.intersection(viewportInChat)
        return !visible.isEmpty && visible.insetBy(dx: -1, dy: -1).contains(needed)
    }
}

/// Observation only; the legacy probe's lifetime counters and modes remain unchanged.
@MainActor
final class ActivityMotionPhaseAudit {
    private unowned let controller: ChatActivityController
    private let log: (String) -> Void
    private var appeared = false
    private var firstVisible: [String: Any] = [:]
    private var opening = ActivityMotionPhaseWindow()
    private var openingStarted = false
    private var post = ActivityMotionPhaseWindow()
    private var shelfGeometryError: CGFloat = 0
    private var shelfOpacityError: CGFloat = 0
    private var shelfTransformError: CGFloat = 0
    private var shelfPresentationSamples = 0
    private var shelfPresentationMissing = 0
    private var previousSurfaceModels: [ObjectIdentifier: ActivityShelfPresentationCheck] = [:]
    private var viewportSamples: [(ActivityShelfVisibilityCheck, ActivityShelfVisibilityCheck)] = []

    init(controller: ChatActivityController, log: @escaping (String) -> Void) {
        self.controller = controller
        self.log = log
    }

    func start() {
        appeared = false
        firstVisible = [:]
        opening = ActivityMotionPhaseWindow()
        openingStarted = false
        post = ActivityMotionPhaseWindow()
        shelfGeometryError = 0
        shelfOpacityError = 0
        shelfTransformError = 0
        shelfPresentationSamples = 0
        shelfPresentationMissing = 0
        previousSurfaceModels = [:]
        viewportSamples = []
        log("phaseAudit start")
    }

    private func rectangle(_ view: UIView) -> CGRect? {
        guard let window = view.window, let layer = view.layer.presentation() else { return nil }
        return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
    }

    private func visibleRows() -> [String: CGRect] {
        let table = controller.chat.tableView
        guard let window = table.window else { return [:] }
        var rows: [String: CGRect] = [:]
        for cell in table.visibleCells {
            guard let cell = cell as? ChatBaseCell, let rect = rectangle(cell),
                  !rect.intersection(window.bounds).isEmpty else { continue }
            rows[cell.rowId] = rect
        }
        return rows
    }

    private var inset: CGFloat {
        let table = controller.chat.tableView
        return ActivityMotionPhaseWindow.renderedInset(modelInset: table.contentInset.top,
            modelOffset: table.layer.bounds.minY,
            presentationOffset: table.layer.presentation()?.bounds.minY ?? table.layer.bounds.minY)
    }
    private var shelfExtent: CGFloat {
        let height = controller.shelf.layer.presentation()?.bounds.height ?? controller.shelf.bounds.height
        return height > 0.5 ? height + ActivityShelfView.gap : 0
    }

    /// Exclude navigation ancestors: the chat itself can be partly outside the window.
    private func visibility(_ view: UIView) -> ActivityShelfVisibilityCheck {
        let chat = controller.chat.view!
        let window = chat.window
        let chatLayer = chat.layer.presentation() ?? chat.layer
        let presented = view.layer.presentation()
        let actual = presented.map { $0.convert($0.bounds, to: chatLayer) } ?? .null
        let shelf = controller.shelf
        let shelfWidth = max(0, chat.bounds.width - 2 * controller.chat.dockSideInset)
        let shelfHeight = shelf.bounds.height > 0 ? shelf.bounds.height : 44
        let isHeader = view === shelf.summaryHeader
        let width = isHeader ? min(shelfWidth, shelf.summaryHeader.fittingWidth) : shelfWidth
        let size = CGSize(width: max(1, width), height: isHeader ? shelf.summaryHeader.height(width: shelfWidth) : shelfHeight)
        // The dock base and layout contract provide a footprint independent of shelf visibility,
        // attachment, or its own frame. The header is centered at the shelf's top.
        let base = controller.chat.voice.notice.layer.convert(controller.chat.voice.notice.layer.bounds, to: chat.layer)
        let expected = CGRect(x: chat.bounds.midX - size.width / 2,
                              y: base.minY - ActivityShelfView.gap - shelfHeight,
                              width: size.width, height: size.height)
        let viewport = window.map { chatLayer.convert($0.bounds, from: $0.layer.presentation() ?? $0.layer) } ?? .null
        var node: UIView? = view
        var attached = window != nil && presented != nil
        var opacity: CGFloat = 1
        var clip = chat.bounds
        while let current = node {
            if current.isHidden { attached = false }
            guard let layer = current.layer.presentation() else { attached = false; break }
            opacity *= CGFloat(layer.opacity)
            if current.clipsToBounds { clip = clip.intersection(layer.convert(layer.bounds, to: chatLayer)) }
            if current === chat { break }    // Include the root, but not navigation ancestors.
            node = current.superview
        }
        if node !== chat { attached = false }
        if !clip.insetBy(dx: -1, dy: -1).contains(actual) { attached = false }
        return ActivityShelfVisibilityCheck(expected: expected, actual: actual, chat: chat.bounds,
                                            viewportInChat: viewport, attached: attached, opacity: opacity)
    }

    private func sampleShelfPresentation() {
        let chat = controller.chat.view!
        let chatLayer = chat.layer.presentation() ?? chat.layer
        let shelf = controller.shelf
        let shouldSample = ActivityShelfPresentationCheck.needsSampling(model: shelf.layer,
            presentation: shelf.layer.presentation(), headerPresentation: shelf.summaryHeader.layer.presentation())
        for view in [shelf, shelf.summaryHeader] as [UIView] {
            let id = ObjectIdentifier(view)
            let layer = view.layer.presentation()
            let observation = ActivityShelfPresentationCheck.capture(model: view.layer, chat: chat.layer,
                presentation: layer ?? view.layer, presentationChat: layer == nil ? chat.layer : chatLayer)
            // Remember even the empty model before cold hydration. The fallback above only
            // retains model fields; absent presentation never contributes a passing sample.
            defer { previousSurfaceModels[id] = observation }
            guard shouldSample else { continue }
            guard layer != nil else { shelfPresentationMissing += 1; continue }
            let check = observation.alignedWithPreviousModel(previousSurfaceModels[id])
            shelfPresentationSamples += 1
            shelfGeometryError = max(shelfGeometryError, check.geometryError)
            shelfOpacityError = max(shelfOpacityError, check.opacityError)
            shelfTransformError = max(shelfTransformError, check.transformError)
        }
    }

    /// Take the final opening observation and a fresh baseline at the actual appearance callback.
    func didAppear() {
        let rows = visibleRows()
        if openingStarted { opening.sample(rows: rows, inset: inset, shelfExtent: shelfExtent) }
        appeared = true
        post.reset(rows: rows)
        log("phaseAudit didAppear rows=\(rows.count) chatX=\(rectangle(controller.chat.view)?.minX ?? -1) coordinator=\(controller.chat.transitionCoordinator != nil)")
    }

    func tick() {
        let rows = visibleRows()
        // Include hydration just after appearance as well as samples during the push.
        sampleShelfPresentation()
        let shelfVisibility = visibility(controller.shelf)
        let headerVisibility = visibility(controller.shelf.summaryHeader)
        if !appeared || post.frames == 0 { viewportSamples.append((shelfVisibility, headerVisibility)) }
        if firstVisible.isEmpty && !rows.isEmpty {
            firstVisible = [
                "firstVisibleLifecycle": appeared ? "afterAppearance" : "beforeAppearance",
                "firstVisibleRows": rows.count,
                "firstChatX": Double(rectangle(controller.chat.view)?.minX ?? -1),
                "firstShelfHeight": Double(controller.shelf.layer.presentation()?.bounds.height ?? -1),
                "firstShelfLabel": controller.shelf.summaryHeader.accessibilityLabel ?? "",
                "firstSampledShelfWithinChat": shelfVisibility.withinChat ? 1 : 0,
                "firstSampledHeaderWithinChat": headerVisibility.withinChat ? 1 : 0,
                "firstSampledShelfWindowVisible": shelfVisibility.visibleWhenEligible ? 1 : 0,
                "firstSampledHeaderWindowVisible": headerVisibility.visibleWhenEligible ? 1 : 0,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: firstVisible, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { log("phaseAudit firstVisible \(text)") }
        }
        if appeared {
            post.sample(rows: rows)
        } else if openingStarted {
            opening.sample(rows: rows, inset: inset, shelfExtent: shelfExtent)
        } else if !rows.isEmpty {
            opening.reset(rows: rows, inset: inset, shelfExtent: shelfExtent)
            openingStarted = true
        }
    }

    var metrics: [String: Any] {
        var result = firstVisible
        result["postAppearanceFrames"] = post.frames
        result["postAppearanceCoveredFrames"] = post.coveredFrames
        result["postAppearanceUncoveredFrames"] = post.uncoveredFrames
        result["postAppearanceIncompleteCoverageFrames"] = post.incompleteCoverageFrames
        result["postAppearanceRows"] = post.tracks.count
        result["postAppearanceBaselineRows"] = post.baselineIDs.count
        result["postAppearanceMatchedRows"] = post.matchedBaselineIDs.count
        result["postAppearanceStill"] = Double(post.still)
        result["postAppearanceStep"] = Double(post.step)
        result["postAppearanceHeight"] = Double(post.height)
        result["postAppearanceHorizontal"] = Double(post.horizontal)
        result["postAppearanceWidth"] = Double(post.width)
        result["postAppearanceReversals"] = post.reversals
        result["openingFrames"] = opening.frames
        result["openingCoveredFrames"] = opening.coveredFrames
        result["openingUncoveredFrames"] = opening.uncoveredFrames
        result["openingIncompleteCoverageFrames"] = opening.incompleteCoverageFrames
        result["openingBaselineRows"] = opening.baselineIDs.count
        result["openingMatchedRows"] = opening.matchedBaselineIDs.count
        result["openingMoves"] = opening.moves
        result["openingStep"] = Double(opening.step)
        result["openingExcessMotion"] = Double(opening.excessMotion)
        result["openingHeight"] = Double(opening.height)
        result["openingReversals"] = opening.reversals
        result["openingAnchorError"] = Double(opening.anchorError)
        result["openingInsetShelfError"] = Double(opening.insetShelfError)
        result["openingShelfPresentationSamples"] = shelfPresentationSamples
        result["openingShelfPresentationMissing"] = shelfPresentationMissing
        result["openingShelfGeometryError"] = Double(shelfGeometryError)
        result["openingShelfOpacityError"] = Double(shelfOpacityError)
        result["openingShelfTransformError"] = Double(shelfTransformError)
        // Replay the first sampled expected-footprint entry against settled model geometry. This
        // doesn't wait for an actually visible shelf, nor assume an early window intersection.
        let expectedShelf = visibility(controller.shelf).expected
        let expectedHeader = visibility(controller.shelf.summaryHeader).expected
        for (shelf, header) in viewportSamples {
            let h = ActivityShelfVisibilityCheck(expected: expectedHeader, actual: header.actual, chat: header.chat,
                                                 viewportInChat: header.viewportInChat, attached: header.attached, opacity: header.opacity)
            let s = ActivityShelfVisibilityCheck(expected: expectedShelf, actual: shelf.actual, chat: shelf.chat,
                                                 viewportInChat: shelf.viewportInChat, attached: shelf.attached, opacity: shelf.opacity)
            if result["firstExpectedViewportShelfVisible"] == nil && s.eligible {
                result["firstExpectedViewportShelfVisible"] = s.visibleWhenEligible ? 1 : 0
            }
            if result["firstExpectedViewportHeaderVisible"] == nil && h.eligible {
                result["firstExpectedViewportHeaderVisible"] = h.visibleWhenEligible ? 1 : 0
            }
            if result["firstExpectedViewportShelfVisible"] != nil && result["firstExpectedViewportHeaderVisible"] != nil { break }
        }
        return result
    }
}
#endif
