import CoreGraphics
import Foundation

/// An output page and the clips on it, back to front.
struct ComposedPage: Identifiable, Equatable {
    var id = UUID()
    var widthMm: Double
    var heightMm: Double
    var clips: [Clip] = []

    static func create(_ paper: PaperSize, landscape: Bool) -> ComposedPage {
        ComposedPage(widthMm: landscape ? paper.heightMm : paper.widthMm,
                     heightMm: landscape ? paper.widthMm : paper.heightMm)
    }

    var isLandscape: Bool { widthMm > heightMm }
    var size: CGSize { CGSize(width: widthMm, height: heightMm) }
    var paper: PaperSize? { PaperSize.matching(width: widthMm, height: heightMm) }

    func find(_ id: UUID) -> Clip? { clips.first { $0.id == id } }

    /// Replaces the clip with the same id, or adds it on top.
    func with(_ clip: Clip) -> ComposedPage {
        var p = self
        if let i = p.clips.firstIndex(where: { $0.id == clip.id }) { p.clips[i] = clip } else { p.clips.append(clip) }
        return p
    }

    func without(_ id: UUID) -> ComposedPage {
        var p = self
        p.clips.removeAll { $0.id == id }
        return p
    }

    func bringingToFront(_ id: UUID) -> ComposedPage {
        guard let c = find(id) else { return self }
        var p = without(id)
        p.clips.append(c)
        return p
    }

    func sendingToBack(_ id: UUID) -> ComposedPage {
        guard let c = find(id) else { return self }
        var p = without(id)
        p.clips.insert(c, at: 0)
        return p
    }
}

/// The whole layout: every output page, in order.
struct Composition: Equatable {
    var pages: [ComposedPage]

    static func create(_ paper: PaperSize, landscape: Bool) -> Composition {
        Composition(pages: [.create(paper, landscape: landscape)])
    }

    func usesSource(_ sourceID: String) -> Bool {
        pages.contains { $0.clips.contains { $0.sourceID == sourceID } }
    }

    var isEmpty: Bool { pages.allSatisfy { $0.clips.isEmpty } }
}
