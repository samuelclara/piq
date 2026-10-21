import Foundation

/// One decision in a sorting session. The undo history is a list of these, in the order they were
/// made.
struct SortDecision: Codable, Hashable, Sendable {
    let assetID: String
    let action: SwipeAction
    /// Where the photo stood before, when this decision replaced an earlier one (the person went
    /// back to a decided photo and decided again); nil for a photo's first decision. Undo puts it
    /// back exactly.
    var replaced: Verdict?
}

/// Where a decided photo stands: what was decided, and whether the photo is in Piq's trash (a
/// photo marked for deletion and then restored in Review is not).
struct Verdict: Codable, Hashable, Sendable {
    let action: SwipeAction
    let isMarked: Bool
}

/// A move to the photo before or after the one on screen that decides nothing (the Previous and
/// Next buttons). Moves aren't undoable.
enum PhotoStep: Sendable {
    case previous
    case next
}

/// The pure, testable core of a sorting session: the album's photos in order, a cursor on the
/// photo on screen, and a decision per photo.
///
/// Photos are decided in any order: a decision moves the cursor on to the next photo, Previous
/// and Next move it without deciding (a skipped photo stays unsorted), and going back to a decided
/// photo and deciding again replaces its decision. Invariants: every decided photo is in
/// `assetIDs`, every photo in the trash is decided `.delete`, and replaying `history` from an
/// undecided session gives `decisions` (each entry's `replaced` is the photo's decision before it).
struct SortingState: Hashable, Sendable {
    /// Image asset identifiers, oldest first.
    private(set) var assetIDs: [String]
    /// The cursor: the index of the photo on screen, or `total` once it has moved past the last
    /// photo.
    private(set) var currentIndex: Int
    /// Each decided photo's decision. A photo with none is unsorted.
    private(set) var decisions: [String: SwipeAction]
    /// Undo history: every decision in the order it was made, a replaced one included.
    private(set) var history: [SortDecision]
    /// Piq's trash: photos marked for deletion. Nothing is deleted from Photos until the trash is
    /// emptied.
    private(set) var markedIDs: Set<String>

    init(assetIDs: [String]) {
        self.assetIDs = Self.removingDuplicates(assetIDs).ids
        self.currentIndex = 0
        self.decisions = [:]
        self.history = []
        self.markedIDs = []
    }

    /// Rebuilds a state saved the way builds before navigation saved it, where sorting was a
    /// prefix: the first `currentIndex` photos sorted in order, `history[i]` deciding `assetIDs[i]`.
    /// Repairs anything that breaks that: a missing or wrong entry is rebuilt from the trash.
    init(assetIDs: [String], currentIndex: Int, markedIDs: some Sequence<String>, history: [SortDecision]) {
        let ids = Self.removingDuplicates(assetIDs).ids
        let index = min(max(currentIndex, 0), ids.count)
        let marked = Set(markedIDs)
        var repaired: [SortDecision] = []
        repaired.reserveCapacity(index)
        for position in 0..<index {
            let id = ids[position]
            if position < history.count, history[position].assetID == id {
                repaired.append(SortDecision(assetID: id, action: history[position].action))
            } else {
                repaired.append(SortDecision(assetID: id, action: marked.contains(id) ? .delete : .keep))
            }
        }
        self.assetIDs = ids
        self.currentIndex = index
        self.decisions = Dictionary(repaired.lazy.map { ($0.assetID, $0.action) }, uniquingKeysWith: { _, last in last })
        self.history = repaired
        self.markedIDs = marked.intersection(ids.prefix(index))
    }

    /// Rebuilds a state from its parts, repairing anything that breaks the invariants: decisions
    /// and history of photos not in `assetIDs` go, the trash keeps only photos decided `.delete`,
    /// and a history that doesn't add up to `decisions` is replaced by the decided photos in
    /// session order (so Undo still takes back each decision once).
    init(assetIDs: [String], currentIndex: Int, decisions: [String: SwipeAction], markedIDs: some Sequence<String>, history: [SortDecision]) {
        let (ids, present) = Self.removingDuplicates(assetIDs)
        let decided = decisions.keys.allSatisfy(present.contains) ? decisions : decisions.filter { present.contains($0.key) }
        self.assetIDs = ids
        self.currentIndex = min(max(currentIndex, 0), ids.count)
        self.decisions = decided
        self.markedIDs = Set(markedIDs).filter { decided[$0] == .delete }
        if Self.history(history, addsUpTo: decided) {
            self.history = history
        } else {
            self.history = ids.compactMap { id in decided[id].map { SortDecision(assetID: id, action: $0) } }
        }
    }

    // MARK: Reading

    var total: Int { assetIDs.count }
    var sortedCount: Int { decisions.count }
    var markedCount: Int { markedIDs.count }
    var keptCount: Int { sortedCount - markedCount }
    var remainingCount: Int { total - sortedCount }
    /// Every photo is decided.
    var isComplete: Bool { sortedCount >= total }
    var hasProgress: Bool { sortedCount > 0 || markedCount > 0 }
    var canUndo: Bool { !history.isEmpty }
    /// There is a photo before the cursor to go back to.
    var canGoBack: Bool { currentIndex > 0 }
    /// There is a photo on screen to move on from (past the last one, the cursor reaches the end).
    var canGoForward: Bool { currentIndex < total }
    /// 1-based position for "38 of 400", clamped to the total once past the last photo.
    var position: Int { min(currentIndex + 1, total) }
    var progress: Double { total == 0 ? 0 : Double(sortedCount) / Double(total) }
    /// "Resume · 38 of 400" (the first unsorted photo), or nil when there is nothing worth resuming.
    var resumePoint: ResumePoint? {
        ResumePoint(total: total, sorted: sortedCount, marked: markedCount, firstUnsortedIndex: firstUnsortedIndex ?? total)
    }
    var currentAssetID: String? { currentIndex < total ? assetIDs[currentIndex] : nil }
    var lastDecision: SortDecision? { history.last }
    /// The index of the first photo nobody has decided yet, or nil when every photo is decided.
    var firstUnsortedIndex: Int? {
        guard !isComplete else { return nil }
        return assetIDs.firstIndex { decisions[$0] == nil }
    }

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

    /// The photo's decision and whether it is in the trash, or nil while it is unsorted.
    func verdict(for assetID: String) -> Verdict? {
        decisions[assetID].map { Verdict(action: $0, isMarked: markedIDs.contains(assetID)) }
    }

    /// Marked photos in session order (oldest first), for the review grid.
    var markedInOrder: [String] {
        guard !markedIDs.isEmpty else { return [] }
        return assetIDs.filter { markedIDs.contains($0) }
    }

    // MARK: Changing

    /// Applies `action` to the photo on screen, replacing any earlier decision of it, and moves
    /// on to the next one.
    @discardableResult
    mutating func apply(_ action: SwipeAction) -> SortDecision? {
        guard let assetID = currentAssetID else { return nil }
        let decision = SortDecision(assetID: assetID, action: action, replaced: verdict(for: assetID))
        history.append(decision)
        decisions[assetID] = action
        if action.marksForDeletion {
            markedIDs.insert(assetID)
        } else {
            markedIDs.remove(assetID)
        }
        currentIndex += 1
        return decision
    }

    /// Reverses the last decision (putting back the one it replaced, if any) and goes back to its
    /// photo.
    @discardableResult
    mutating func undo() -> SortDecision? {
        guard let decision = history.popLast() else { return nil }
        let id = decision.assetID
        if let replaced = decision.replaced {
            decisions[id] = replaced.action
            if replaced.isMarked {
                markedIDs.insert(id)
            } else {
                markedIDs.remove(id)
            }
        } else {
            decisions[id] = nil
            markedIDs.remove(id)
        }
        if let index = assetIDs.firstIndex(of: id) {
            currentIndex = index
        }
        return decision
    }

    /// Moves the cursor one photo back or on, deciding nothing. Next on the last photo moves past
    /// it, to the end. Returns whether the cursor moved.
    @discardableResult
    mutating func step(_ step: PhotoStep) -> Bool {
        switch step {
        case .previous:
            guard canGoBack else { return false }
            currentIndex -= 1
        case .next:
            guard canGoForward else { return false }
            currentIndex += 1
        }
        return true
    }

    /// Puts the cursor on the first unsorted photo (past the last photo when every one is
    /// decided), where resuming picks up. Returns whether the cursor moved.
    @discardableResult
    mutating func goToFirstUnsorted() -> Bool {
        let index = firstUnsortedIndex ?? total
        guard index != currentIndex else { return false }
        currentIndex = index
        return true
    }

    /// Takes photos off the trash list ("Restore"). They stay sorted and now count as kept.
    mutating func unmark(_ assetIDs: some Sequence<String>) {
        markedIDs.subtract(assetIDs)
    }

    /// Drops photos that no longer exist (deleted by Piq or outside it). The cursor stays on the
    /// same photo, or on the one after it when that photo is gone.
    mutating func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let before = assetIDs[..<currentIndex].reduce(0) { $0 + (ids.contains($1) ? 1 : 0) }
        assetIDs.removeAll { ids.contains($0) }
        currentIndex = min(currentIndex - before, assetIDs.count)
        for id in ids {
            decisions[id] = nil
        }
        history.removeAll { ids.contains($0.assetID) }
        markedIDs.subtract(ids)
    }

    /// Brings the session in line with the album's current contents (`albumAssetIDs`, oldest
    /// first): photos that left the album drop out of the session, its decisions and the trash,
    /// and photos new to the session are queued unsorted. The photos before the cursor keep their
    /// order and the cursor stays on the photo on screen; the photos after it follow the album, so
    /// a new photo comes up in album order (one older than the photo on screen right after it).
    ///
    /// `keepingSortedPhotos` is for limited access, where a photo the album doesn't list may only
    /// be outside the person's selection: decided photos then stay, with their decisions and the
    /// trash (those after the cursor at the end, in session order), and only unsorted photos
    /// follow the album. Returns whether anything changed.
    ///
    /// Every library change reconciles every saved session, and most leave the album as it was:
    /// that case costs one comparison, even for a Recents of tens of thousands of photos.
    @discardableResult
    mutating func reconcile(albumAssetIDs: [String], keepingSortedPhotos: Bool = false) -> Bool {
        // The album lists exactly the session's photos, in session order: nothing left, nothing
        // new, and the cursor is on the same photo.
        guard albumAssetIDs != assetIDs else { return false }
        let listed = Set(albumAssetIDs)
        func stays(_ id: String) -> Bool {
            listed.contains(id) || (keepingSortedPhotos && decisions[id] != nil)
        }
        var newIDs: [String] = []
        newIDs.reserveCapacity(max(assetIDs.count, albumAssetIDs.count))
        // The photos up to the cursor that stay (and the photo on screen), so the album's photos
        // after them can be told apart; and the session's photos that go.
        var placed = Set<String>(minimumCapacity: currentIndex + 1)
        var gone: [String] = []
        for id in assetIDs[..<min(currentIndex + 1, total)] {
            if stays(id) {
                newIDs.append(id)
                placed.insert(id)
            } else {
                gone.append(id)
            }
        }
        let cursor = currentAssetID.map { placed.contains($0) } == true ? newIDs.count - 1 : newIDs.count
        if listed.count == albumAssetIDs.count {
            for id in albumAssetIDs where !placed.contains(id) {
                newIDs.append(id)
            }
        } else {
            for id in albumAssetIDs where placed.insert(id).inserted {
                newIDs.append(id)
            }
        }
        // After the cursor: photos the album lists are placed above; decided ones it doesn't list
        // stay with limited access, at the end; the rest go.
        if currentIndex + 1 < total {
            for id in assetIDs[(currentIndex + 1)...] where !listed.contains(id) {
                if keepingSortedPhotos, decisions[id] != nil {
                    newIDs.append(id)
                } else {
                    gone.append(id)
                }
            }
        }
        guard newIDs != assetIDs || cursor != currentIndex else { return false }
        assetIDs = newIDs
        currentIndex = cursor
        if !gone.isEmpty {
            let goneSet = Set(gone)
            for id in gone {
                decisions[id] = nil
            }
            history.removeAll { goneSet.contains($0.assetID) }
            markedIDs.subtract(goneSet)
        }
        return true
    }

    // MARK: Private

    /// Whether replaying `history` from an undecided session gives exactly `decisions`, with
    /// every entry's `replaced` the photo's decision before it, and only deletes in the trash.
    private static func history(_ history: [SortDecision], addsUpTo decisions: [String: SwipeAction]) -> Bool {
        var replayed: [String: SwipeAction] = [:]
        replayed.reserveCapacity(decisions.count)
        for decision in history {
            guard decisions[decision.assetID] != nil,
                  decision.replaced?.action == replayed[decision.assetID],
                  decision.replaced.map({ !$0.isMarked || $0.action.marksForDeletion }) ?? true else { return false }
            replayed[decision.assetID] = decision.action
        }
        return replayed == decisions
    }

    /// `ids` without repeats, and the set of them.
    private static func removingDuplicates(_ ids: [String]) -> (ids: [String], set: Set<String>) {
        var seen = Set<String>(minimumCapacity: ids.count)
        let unique = ids.filter { seen.insert($0).inserted }
        return (unique, seen)
    }
}
