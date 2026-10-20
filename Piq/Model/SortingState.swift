import Foundation

/// One decision in a sorting session. The undo history is a list of these.
struct SortDecision: Codable, Hashable, Sendable {
    let assetID: String
    let action: SwipeAction
}

/// The pure, testable core of a sorting session.
///
/// Invariant: `history[i].assetID == assetIDs[i]` for every decision, so the number of
/// decisions is also the index of the photo on screen; and every photo in the trash is a sorted
/// one.
struct SortingState: Hashable, Sendable {
    /// Image asset identifiers, oldest first.
    private(set) var assetIDs: [String]
    /// Undo history: one entry per sorted photo, in order.
    private(set) var history: [SortDecision]
    /// Piq's trash: sorted photos marked for deletion. Nothing is deleted from Photos until
    /// the trash is emptied.
    private(set) var markedIDs: Set<String>

    init(assetIDs: [String]) {
        self.assetIDs = Self.removingDuplicates(assetIDs)
        self.history = []
        self.markedIDs = []
    }

    /// Rebuilds a state from persisted fields, repairing anything that breaks the invariant.
    init(assetIDs: [String], currentIndex: Int, markedIDs: some Sequence<String>, history: [SortDecision]) {
        let ids = Self.removingDuplicates(assetIDs)
        let index = min(max(currentIndex, 0), ids.count)
        let marked = Set(markedIDs)
        var repaired: [SortDecision] = []
        repaired.reserveCapacity(index)
        for position in 0..<index {
            let id = ids[position]
            if position < history.count, history[position].assetID == id {
                repaired.append(history[position])
            } else {
                repaired.append(SortDecision(assetID: id, action: marked.contains(id) ? .delete : .keep))
            }
        }
        self.assetIDs = ids
        self.history = repaired
        self.markedIDs = marked.intersection(ids.prefix(index))
    }

    // MARK: Reading

    var total: Int { assetIDs.count }
    /// Index of the photo on screen, which is also the number of sorted photos.
    var currentIndex: Int { history.count }
    var sortedCount: Int { history.count }
    var markedCount: Int { markedIDs.count }
    var keptCount: Int { sortedCount - markedCount }
    var remainingCount: Int { total - sortedCount }
    var isComplete: Bool { currentIndex >= total }
    var hasProgress: Bool { sortedCount > 0 || markedCount > 0 }
    var canUndo: Bool { !history.isEmpty }
    /// 1-based position for "38 of 400", clamped to the total once everything is sorted.
    var position: Int { min(currentIndex + 1, total) }
    var progress: Double { total == 0 ? 0 : Double(sortedCount) / Double(total) }
    /// "Resume · 38 of 400", or nil when there is nothing worth resuming.
    var resumePoint: ResumePoint? { ResumePoint(total: total, sorted: sortedCount, marked: markedCount) }
    var currentAssetID: String? { currentIndex < total ? assetIDs[currentIndex] : nil }
    var lastDecision: SortDecision? { history.last }

    /// Up to `count` photos after the current one.
    func upcomingAssetIDs(_ count: Int) -> [String] {
        let start = currentIndex + 1
        guard count > 0, start < total else { return [] }
        return Array(assetIDs[start..<min(start + count, total)])
    }

    /// The current photo followed by up to `lookahead` upcoming ones.
    func window(lookahead: Int) -> [String] {
        guard let current = currentAssetID else { return [] }
        return [current] + upcomingAssetIDs(lookahead)
    }

    func isMarked(_ assetID: String) -> Bool { markedIDs.contains(assetID) }

    /// Marked photos in session order (oldest first), for the review grid.
    var markedInOrder: [String] {
        guard !markedIDs.isEmpty else { return [] }
        return assetIDs.prefix(currentIndex).filter { markedIDs.contains($0) }
    }

    // MARK: Changing

    /// Applies `action` to the photo on screen and moves on to the next one.
    @discardableResult
    mutating func apply(_ action: SwipeAction) -> SortDecision? {
        guard let assetID = currentAssetID else { return nil }
        let decision = SortDecision(assetID: assetID, action: action)
        history.append(decision)
        if action.marksForDeletion { markedIDs.insert(assetID) }
        return decision
    }

    /// Goes back to the previous photo and reverses its decision.
    @discardableResult
    mutating func undo() -> SortDecision? {
        guard let decision = history.popLast() else { return nil }
        markedIDs.remove(decision.assetID)
        return decision
    }

    /// Takes photos off the trash list ("Restore"). They stay sorted and now count as kept.
    mutating func unmark(_ assetIDs: some Sequence<String>) {
        markedIDs.subtract(assetIDs)
    }

    /// Drops photos that no longer exist (deleted by Piq or outside it).
    mutating func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        assetIDs.removeAll { ids.contains($0) }
        history.removeAll { ids.contains($0.assetID) }
        markedIDs.subtract(ids)
    }

    /// Brings the session in line with the album's current contents (`albumAssetIDs`, oldest
    /// first): photos that left the album drop out of the session and the trash, sorted photos
    /// keep their order, and the unsorted queue follows the album so new photos get sorted too.
    ///
    /// `keepingSortedPhotos` is for limited access, where a photo the album doesn't list may only
    /// be outside the person's selection: the sorted photos and the trash then stay as they are,
    /// and only the unsorted queue follows the album. Returns whether anything changed.
    ///
    /// Every library change reconciles every saved session, and most leave the album as it was:
    /// that case costs one comparison, even for a Recents of tens of thousands of photos.
    @discardableResult
    mutating func reconcile(albumAssetIDs: [String], keepingSortedPhotos: Bool = false) -> Bool {
        // The album lists exactly the session's photos, in session order: nothing left, nothing
        // new, and the trash is within the sorted photos (see the invariant).
        guard albumAssetIDs != assetIDs else { return false }
        var keptHistory = history
        if !keepingSortedPhotos {
            let present = Set(albumAssetIDs)
            keptHistory.removeAll { !present.contains($0.assetID) }
        }
        var newIDs = keptHistory.map(\.assetID)
        var seen = Set<String>(minimumCapacity: newIDs.count + albumAssetIDs.count)
        seen.formUnion(newIDs)
        newIDs.reserveCapacity(albumAssetIDs.count)
        for id in albumAssetIDs where seen.insert(id).inserted {
            newIDs.append(id)
        }
        // The trash is within the sorted photos, so it changes only if one of them left.
        let newMarked = keptHistory.count == history.count ? markedIDs : markedIDs.intersection(keptHistory.lazy.map(\.assetID))
        guard newIDs != assetIDs || keptHistory.count != history.count || newMarked != markedIDs else {
            return false
        }
        assetIDs = newIDs
        history = keptHistory
        markedIDs = newMarked
        return true
    }

    private static func removingDuplicates(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
