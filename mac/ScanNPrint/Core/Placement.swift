import CoreGraphics
import Foundation

enum AutoPlacement {
    /// The first free spot, reading top-to-bottom then left-to-right, where a `width` × `height` box fits
    /// inside the margins without touching existing clips (keeping `gap` mm between them). Nil if the page is full.
    static func findFreeSpot(on page: ComposedPage, width: Double, height: Double, margin: Double, gap: Double) -> CGRect? {
        let area = CGRect(x: margin, y: margin, width: page.widthMm - 2 * margin, height: page.heightMm - 2 * margin)
        let occupied = page.clips.map(\.bounds)

        // Candidate corners: the margin origin, then beside and below every existing clip.
        var candidates = [CGPoint(x: area.minX, y: area.minY)]
        for b in occupied {
            candidates.append(CGPoint(x: b.maxX + gap, y: b.minY))
            candidates.append(CGPoint(x: b.minX, y: b.maxY + gap))
            candidates.append(CGPoint(x: area.minX, y: b.maxY + gap))
        }

        // Clips may sit partly in the margin; their neighbours still start inside it.
        let ordered = candidates
            .map { CGPoint(x: max($0.x, area.minX), y: max($0.y, area.minY)) }
            .sorted { a, b in
                let ay = (a.y * 1000).rounded(), by = (b.y * 1000).rounded()
                return ay != by ? ay < by : a.x < b.x
            }
        for corner in ordered {
            let spot = CGRect(x: corner.x, y: corner.y, width: width, height: height)
            if area.containsRect(spot) && !occupied.contains(where: { $0.insetBy(dx: -(gap - 1e-6), dy: -(gap - 1e-6)).overlaps(spot) }) {
                return spot
            }
        }
        return nil
    }
}

/// How far to shift so a moving edge lands on a guide, and which guide it is (nil = no snap).
struct Snap: Equatable {
    var offset: Double
    var guide: Double?

    static let none = Snap(offset: 0, guide: nil)
}

enum Snapping {
    /// The smallest shift (within `threshold`) that puts any of the moving coordinates exactly on any target.
    static func find(_ moving: [Double], _ targets: [Double], threshold: Double) -> Snap {
        var best = Snap.none
        var bestDistance = threshold
        for m in moving {
            for t in targets {
                let d = abs(t - m)
                if d <= bestDistance {
                    bestDistance = d
                    best = Snap(offset: t - m, guide: t)
                }
            }
        }
        return best
    }

    /// Vertical guide lines: page edges, margins, centre, and the edges and centres of other clips.
    static func guidesX(_ page: ComposedPage, margin: Double, excluding: UUID?) -> [Double] {
        var g = [0, margin, page.widthMm / 2, page.widthMm - margin, page.widthMm]
        for c in page.clips where c.id != excluding {
            let b = c.bounds
            g += [b.minX, b.midX, b.maxX]
        }
        return g
    }

    /// Horizontal guide lines, as `guidesX`.
    static func guidesY(_ page: ComposedPage, margin: Double, excluding: UUID?) -> [Double] {
        var g = [0, margin, page.heightMm / 2, page.heightMm - margin, page.heightMm]
        for c in page.clips where c.id != excluding {
            let b = c.bounds
            g += [b.minY, b.midY, b.maxY]
        }
        return g
    }

    /// Snaps a moved box: its left/centre/right to vertical guides and top/centre/bottom to horizontal ones.
    static func snapBox(_ box: CGRect, guidesX: [Double], guidesY: [Double], threshold: Double) -> (x: Snap, y: Snap) {
        (find([box.minX, box.midX, box.maxX], guidesX, threshold: threshold),
         find([box.minY, box.midY, box.maxY], guidesY, threshold: threshold))
    }
}

/// Undo/redo over immutable states.
struct History<T: Equatable> {
    private(set) var current: T
    private var undoStack: [T] = []
    private var redoStack: [T] = []
    private let limit: Int

    init(_ initial: T, limit: Int = 200) {
        current = initial
        self.limit = limit
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records a finished change as one undo step.
    mutating func apply(_ state: T) {
        guard state != current else { return }
        undoStack.append(current)
        if undoStack.count > limit { undoStack.removeFirst() }
        redoStack.removeAll()
        current = state
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        current = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        current = next
    }

    /// Replaces the state and forgets all history (e.g. after opening a project).
    mutating func reset(_ state: T) {
        undoStack.removeAll()
        redoStack.removeAll()
        current = state
    }
}
