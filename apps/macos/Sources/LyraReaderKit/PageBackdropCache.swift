import Foundation

/// Small page images for revisiting a page after its sharp working set has moved away.
/// These are reductions of already completed rasters: retaining one never queues PDFium work.
struct PageBackdropCache {
    private struct Entry { let image: PageImage; var used: UInt64 }
    private var entries: [Int: Entry] = [:]
    private var tick: UInt64 = 0
    let budgetBytes: Int
    private(set) var usedBytes = 0

    init(budgetBytes: Int = 8 * 1024 * 1024) { self.budgetBytes = max(0, budgetBytes) }
    func contains(_ page: Int) -> Bool { entries[page] != nil }
    mutating func image(for page: Int) -> PageImage? {
        guard var entry = entries[page] else { return nil }
        tick &+= 1; entry.used = tick; entries[page] = entry
        return entry.image
    }
    mutating func insert(_ image: PageImage, for page: Int) {
        guard image.bgra.count <= budgetBytes else { return }
        if let old = entries.removeValue(forKey: page) { usedBytes -= old.image.bgra.count }
        tick &+= 1
        entries[page] = Entry(image: image, used: tick)
        usedBytes += image.bgra.count
        while usedBytes > budgetBytes,
              let victim = entries.min(by: { $0.value.used < $1.value.used })?.key,
              let removed = entries.removeValue(forKey: victim) {
            usedBytes -= removed.image.bgra.count
        }
    }
    mutating func removeAll() { entries.removeAll(); usedBytes = 0 }
}
