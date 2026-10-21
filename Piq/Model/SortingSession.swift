import Foundation
import SwiftData

/// One persisted sorting session per album, so sorting can be resumed after quitting.
///
/// Piq saves after every decision and every move, so each writes as little as it can: the photo
/// list, which runs to tens of thousands of identifiers in a large Recents, is a record of its own
/// (`SessionPhotos`) that only a library change or a fresh start rewrites; the decisions take one
/// byte per photo, the cursor one number, and the undo history eight bytes per run of decisions
/// (a session sorted straight through is a single run). (SQLite rewrites a whole row when any of
/// its fields changes.)
@Model
final class SortingSession {
    /// `PHAssetCollection.localIdentifier` of the album being sorted.
    @Attribute(.unique) var albumID: String
    var albumTitle: String
    /// The photos in session order (see `SortingState.assetIDs` and `SortingState.reconcile`).
    @Relationship(deleteRule: .cascade, inverse: \SessionPhotos.session) var photos: SessionPhotos?
    /// How many photos `photos` holds, so the picker's "Resume · 38 of 400" doesn't read the list.
    var photoCount: Int = 0
    /// One byte per photo in session order, up to the last decided one: the letter of its decision
    /// ("k" keep, "d" delete), in upper case while the photo is in Piq's trash, or "." while it is
    /// unsorted. "kD.d" is a keep, a photo marked for deletion, a photo skipped, and a photo marked
    /// for deletion and then restored. Builds before Previous and Next sorted in order, so their
    /// records hold letters only, one per sorted photo.
    var decisions = Data()
    /// The cursor (`SortingState.currentIndex`). Nil in a record saved by a build before Previous
    /// and Next, whose cursor was the number of decisions.
    var cursor: Int? = nil
    /// The undo history, packed by `UndoLog`. Nil in a record saved by a build before Previous and
    /// Next, whose undo history was its decisions in session order.
    var undoLog: Data? = nil
    var createdAt: Date
    /// When the person last worked on the session: opened it, sorted, moved through it, restored
    /// photos or emptied the trash. The picker preselects the most recent unfinished session on
    /// launch, so changes the library makes (photos added or deleted elsewhere, the album renamed)
    /// don't count.
    var updatedAt: Date

    // Earlier builds kept the photo list, the index, the trash and the undo history in this record.
    // `SessionStore` converts a session saved that way when it opens the store (see
    // `convertFromEarlierLayout()`); these are nil from then on.
    @Attribute(originalName: "assetIDs") var legacyAssetIDs: [String]?
    @Attribute(originalName: "currentIndex") var legacyCurrentIndex: Int?
    @Attribute(originalName: "markedIDs") var legacyMarkedIDs: [String]?
    @Attribute(originalName: "historyData") var legacyHistoryData: Data?

    /// A session with no photo list yet: insert it, then give it its photos with
    /// `reset(assetIDs:albumTitle:)`, as `SessionStore.insertSession` does. The list is a record
    /// of its own, related to the session once both are in the same context: the conservative
    /// order for SwiftData, whose iOS 17 versions can't be tested here.
    init(albumID: String, albumTitle: String) {
        self.albumID = albumID
        self.albumTitle = albumTitle
        self.cursor = 0
        self.undoLog = Data()
        self.createdAt = .now
        self.updatedAt = .now
    }

    /// A session of `assetIDs`, its photo list attached before it is inserted anywhere: for tests
    /// and previews (the app creates sessions with `SessionStore.insertSession`).
    convenience init(albumID: String, albumTitle: String, assetIDs: [String]) {
        self.init(albumID: albumID, albumTitle: albumTitle)
        setPhotoList(SortingState(assetIDs: assetIDs).assetIDs)
    }

    /// The session as a `SortingState`, decoded from the stored fields. Setting it writes back
    /// what changed the way a library change does: without counting as the person's work (see
    /// `updatedAt`).
    var state: SortingState {
        get { Self.decode(assetIDs: photos?.assetIDs ?? [], decisions: decisions, cursor: cursor, undoLog: undoLog) }
        set { write(newValue, over: state, touch: false) }
    }

    /// Writes the fields of `state` that differ from `old`, the state the record holds now,
    /// without reading the stored photo list: a session controller keeps its state in memory and
    /// saves its changes this way (decisions, undos and moves the quicker ways below). `touch` is
    /// for a change the person made, which makes this the session they worked on last.
    ///
    /// Afterwards the record is in the current layout, with no byte past its photos (see
    /// `recordDecision(_:at:inTrash:cursor:)`).
    func write(_ state: SortingState, over old: SortingState, touch: Bool) {
        let listChanged = state.assetIDs != old.assetIDs
        if listChanged {
            setPhotoList(state.assetIDs)
        }
        if listChanged || state.decisions != old.decisions || state.markedIDs != old.markedIDs || state.history != old.history
            || cursor == nil || undoLog == nil || decisions.count > photoCount {
            let encoded = Self.encode(state)
            decisions = encoded.decisions
            undoLog = encoded.undoLog
            cursor = state.currentIndex
        } else if cursor != state.currentIndex {
            cursor = state.currentIndex
        }
        if touch {
            updatedAt = .now
        }
    }

    /// Records the decision `SortingState.apply(_:)` just made for the photo at `position`
    /// (`inTrash`: whether it is in the trash now), and the cursor after it. Sorting's hot path:
    /// one letter and one undo-log entry, where `write(_:over:touch:)` would go through the whole
    /// session to find that out, which 29,000 photos into a session costs more than the save.
    ///
    /// Bytes past the photos give way, so the record holds no stale letter (written by another
    /// build, or damaged) that would come back once the photo list grew.
    func recordDecision(_ decision: SortDecision, at position: Int, inTrash: Bool, cursor: Int) {
        var letters = [UInt8](decisions.prefix(photoCount))
        var log = undoLog.map { [UInt8]($0) } ?? UndoLog.inSessionOrder(letters)
        UndoLog.append(position: position, replaced: decision.replaced.map { Self.byte(for: $0.action, inTrash: $0.isMarked) }, to: &log)
        Self.setLetter(Self.byte(for: decision.action, inTrash: inTrash), at: position, in: &letters)
        decisions = Data(letters)
        undoLog = Data(log)
        self.cursor = cursor
        updatedAt = .now
    }

    /// Records `SortingState.undo()` taking back `decision`, the photo at `position`, and the
    /// cursor after it (on that photo): its letter goes back to the one it replaced, or to
    /// unsorted, and the undo log loses its last entry.
    func recordUndo(of decision: SortDecision, at position: Int, cursor: Int) {
        var letters = [UInt8](decisions.prefix(photoCount))
        var log = undoLog.map { [UInt8]($0) } ?? UndoLog.inSessionOrder(letters)
        UndoLog.removeLast(from: &log)
        let letter = decision.replaced.map { Self.byte(for: $0.action, inTrash: $0.isMarked) } ?? Self.unsorted
        Self.setLetter(letter, at: position, in: &letters)
        decisions = Data(letters)
        undoLog = Data(log)
        self.cursor = cursor
        updatedAt = .now
    }

    /// Records a move of the cursor (Previous, Next, resuming at the first unsorted photo).
    func recordCursor(_ cursor: Int) {
        if undoLog == nil {
            undoLog = Data(UndoLog.inSessionOrder([UInt8](decisions.prefix(photoCount))))
        }
        self.cursor = cursor
        updatedAt = .now
    }

    /// Where to pick up again (the first unsorted photo), or nil when there is nothing worth
    /// resuming (never started, or everything sorted and the trash emptied).
    var resumePoint: ResumePoint? {
        let letters = decisions.prefix(photoCount)
        var sorted = 0
        var marked = 0
        var firstUnsorted: Int?
        for (offset, byte) in letters.enumerated() {
            if byte == Self.unsorted {
                firstUnsorted = firstUnsorted ?? offset
            } else {
                sorted += 1
                marked += Self.isInTrash(byte) ? 1 : 0
            }
        }
        return ResumePoint(total: photoCount, sorted: sorted, marked: marked, firstUnsortedIndex: firstUnsorted ?? letters.count)
    }

    /// Starts over with a fresh list of photos.
    func reset(assetIDs: [String], albumTitle: String) {
        self.albumTitle = albumTitle
        setPhotoList(SortingState(assetIDs: assetIDs).assetIDs)
        decisions = Data()
        cursor = 0
        undoLog = Data()
        createdAt = .now
        updatedAt = .now
    }

    private func setPhotoList(_ ids: [String]) {
        if let photos {
            photos.assetIDs = ids
        } else {
            let photos = SessionPhotos(assetIDs: ids)
            modelContext?.insert(photos)
            self.photos = photos
        }
        photoCount = ids.count
    }

    // MARK: Encoding

    /// The state the stored fields describe. A letter this build doesn't know (one written by a
    /// later build) counts as a delete if the photo is in the trash, else as a keep. A record
    /// saved before Previous and Next (`cursor` and `undoLog` nil) reads exactly as that build
    /// read it: its cursor after its decisions, its undo history its decisions in order.
    static func decode(assetIDs: [String], decisions letters: Data, cursor: Int?, undoLog: Data?) -> SortingState {
        var decided: [String: SwipeAction] = [:]
        var marked: [String] = []
        decided.reserveCapacity(min(assetIDs.count, letters.count))
        for (assetID, byte) in zip(assetIDs, letters) where byte != unsorted {
            let inTrash = isInTrash(byte)
            decided[assetID] = action(forLetter: byte | lowercaseBit) ?? (inTrash ? .delete : .keep)
            if inTrash {
                marked.append(assetID)
            }
        }
        let history = undoLog.flatMap { UndoLog.history(from: $0, assetIDs: assetIDs, decisions: decided, verdict: verdict(forLetter:)) }
            ?? assetIDs.compactMap { id in decided[id].map { SortDecision(assetID: id, action: $0) } }
        return SortingState(
            assetIDs: assetIDs,
            currentIndex: cursor ?? min(letters.count, assetIDs.count),
            decisions: decided,
            markedIDs: marked,
            history: history
        )
    }

    /// `decisions` and `undoLog` for `state`. One pass over the photos when the undo history runs
    /// in session order without replacements (sorting straight through, skipping or not), as it
    /// mostly does; otherwise a second pass over the history.
    static func encode(_ state: SortingState) -> (decisions: Data, undoLog: Data) {
        guard !state.decisions.isEmpty else { return (Data(), Data()) }
        let history = state.history
        var letters: [UInt8] = []
        letters.reserveCapacity(state.total)
        var log: [UInt8] = []
        // How much of the history the photos have matched so far, in session order.
        var matched = 0
        var isInSessionOrder = true
        for (position, id) in state.assetIDs.enumerated() {
            guard let action = state.decisions[id] else {
                letters.append(unsorted)
                continue
            }
            letters.append(byte(for: action, inTrash: action.marksForDeletion && state.isMarked(id)))
            if isInSessionOrder, matched < history.count, history[matched].assetID == id, history[matched].replaced == nil {
                UndoLog.append(position: position, replaced: nil, to: &log)
                matched += 1
            } else {
                isInSessionOrder = false
            }
        }
        while letters.last == unsorted {
            letters.removeLast()
        }
        if !isInSessionOrder || matched != history.count {
            var positions: [String: Int] = [:]
            positions.reserveCapacity(state.decisions.count)
            for (position, id) in state.assetIDs.enumerated() where state.decisions[id] != nil {
                positions[id] = position
            }
            log.removeAll()
            for decision in history {
                guard let position = positions[decision.assetID] else { continue }
                UndoLog.append(position: position, replaced: decision.replaced.map { byte(for: $0.action, inTrash: $0.isMarked) }, to: &log)
            }
        }
        return (Data(letters), Data(log))
    }

    /// Sets the letter of the photo at `position`, marking any photos before it that `letters`
    /// doesn't reach yet as unsorted, and drops unsorted ones at the end.
    private static func setLetter(_ letter: UInt8, at position: Int, in letters: inout [UInt8]) {
        if position < letters.count {
            letters[position] = letter
        } else {
            letters.append(contentsOf: repeatElement(unsorted, count: position - letters.count))
            letters.append(letter)
        }
        while letters.last == unsorted {
            letters.removeLast()
        }
    }

    private static func byte(for action: SwipeAction, inTrash: Bool) -> UInt8 {
        let letter = letter(for: action)
        return inTrash ? letter & ~lowercaseBit : letter
    }

    /// The letter that stands for `action` in `decisions`. Saved sessions use these, so never
    /// change one; a new action needs a letter of its own.
    private static func letter(for action: SwipeAction) -> UInt8 {
        switch action {
        case .delete: UInt8(ascii: "d")
        case .keep: UInt8(ascii: "k")
        }
    }

    private static func action(forLetter letter: UInt8) -> SwipeAction? {
        SwipeAction.allCases.first { Self.letter(for: $0) == letter }
    }

    /// The verdict a letter stands for (see `decisions`).
    private static func verdict(forLetter byte: UInt8) -> Verdict {
        let inTrash = isInTrash(byte)
        return Verdict(action: action(forLetter: byte | lowercaseBit) ?? (inTrash ? .delete : .keep), isMarked: inTrash)
    }

    /// The byte of a photo nobody has decided yet, in `decisions` and in the undo log.
    fileprivate static let unsorted = UInt8(ascii: ".")

    /// The ASCII bit that tells a lower-case letter from its upper-case form.
    private static let lowercaseBit: UInt8 = 0x20

    private static func isInTrash(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }

    // MARK: Earlier builds

    /// Whether the session is stored the way earlier builds stored it, all in this record.
    var isInEarlierLayout: Bool { legacyAssetIDs != nil }

    /// Moves a session saved by an earlier build to the current layout, with its progress, trash
    /// and undo history.
    func convertFromEarlierLayout() {
        guard let ids = legacyAssetIDs else { return }
        let history = Self.legacyHistory(from: legacyHistoryData ?? Data(), assetIDs: ids) ?? []
        let state = SortingState(assetIDs: ids, currentIndex: legacyCurrentIndex ?? 0, markedIDs: legacyMarkedIDs ?? [], history: history)
        setPhotoList(state.assetIDs)
        let encoded = Self.encode(state)
        decisions = encoded.decisions
        undoLog = encoded.undoLog
        cursor = state.currentIndex
        legacyAssetIDs = nil
        legacyCurrentIndex = nil
        legacyMarkedIDs = nil
        legacyHistoryData = nil
    }

    /// The undo history as earlier builds stored it for a session of `assetIDs`: a JSON-encoded
    /// `[SortDecision]`, or the actions' names for the first `assetIDs`, comma-separated
    /// ("delete,keep,keep"). Nil when it can't be read (the state then rebuilds it from the trash).
    static func legacyHistory(from data: Data, assetIDs: [String]) -> [SortDecision]? {
        if data.first == UInt8(ascii: "[") {
            return try? JSONDecoder().decode([SortDecision].self, from: data)
        }
        guard !data.isEmpty else { return [] }
        let names = String(decoding: data, as: UTF8.self).split(separator: ",", omittingEmptySubsequences: false)
        guard names.count <= assetIDs.count else { return nil }
        var history: [SortDecision] = []
        history.reserveCapacity(names.count)
        for (index, name) in names.enumerated() {
            guard let action = SwipeAction(rawValue: String(name)) else { return nil }
            history.append(SortDecision(assetID: assetIDs[index], action: action))
        }
        return history
    }
}

/// The undo history as `SortingSession.undoLog` stores it: eight bytes per entry, the position of
/// a photo in the session (4 bytes, little-endian), a count (3 bytes) and the letter of the
/// decision it replaced ("." for none). An entry with no replaced decision covers `count` photos
/// in a row, decided one after the other, so sorting straight through stays one entry. Each
/// decision's own action isn't stored: it is the photo's next entry's replaced letter, or for its
/// last entry the photo's letter in `decisions`.
enum UndoLog {
    static let entrySize = 8
    private static let maxRun = 0xFF_FFFF

    /// Adds a decision of the photo at `position` that replaced the letter `replaced` (nil for a
    /// first decision), extending the last run when it can.
    static func append(position: Int, replaced: UInt8?, to log: inout [UInt8]) {
        let previous = replaced ?? SortingSession.unsorted
        if previous == SortingSession.unsorted, log.count >= entrySize {
            let last = log.count - entrySize
            let entry = read(log, at: last)
            if entry.replaced == SortingSession.unsorted, entry.position + entry.count == position, entry.count < maxRun {
                write(position: entry.position, count: entry.count + 1, replaced: previous, into: &log, at: last)
                return
            }
        }
        log.append(contentsOf: repeatElement(0, count: entrySize))
        write(position: position, count: 1, replaced: previous, into: &log, at: log.count - entrySize)
    }

    /// Takes the last decision off the log.
    static func removeLast(from log: inout [UInt8]) {
        guard log.count >= entrySize else {
            log.removeAll()
            return
        }
        let last = log.count - entrySize
        let entry = read(log, at: last)
        if entry.count > 1 {
            write(position: entry.position, count: entry.count - 1, replaced: entry.replaced, into: &log, at: last)
        } else {
            log.removeLast(entrySize)
        }
    }

    /// The log of a record saved before Previous and Next, whose decisions were its undo history in
    /// session order.
    static func inSessionOrder(_ letters: [UInt8]) -> [UInt8] {
        var log: [UInt8] = []
        for (position, letter) in letters.enumerated() where letter != SortingSession.unsorted {
            append(position: position, replaced: nil, to: &log)
        }
        return log
    }

    /// The undo history `log` describes for a session of `assetIDs` decided as `decisions`, with
    /// `verdict` reading a replaced letter. Nil when the log doesn't fit the session (damaged, or
    /// for another photo list); the state then rebuilds the history from the decisions.
    static func history(from data: Data, assetIDs: [String], decisions: [String: SwipeAction], verdict: (UInt8) -> Verdict) -> [SortDecision]? {
        let log = [UInt8](data)
        guard log.count % entrySize == 0 else { return nil }
        var entries: [(position: Int, replaced: UInt8)] = []
        for start in stride(from: 0, to: log.count, by: entrySize) {
            let entry = read(log, at: start)
            guard entry.count >= 1, entry.position + entry.count <= assetIDs.count,
                  entry.count == 1 || entry.replaced == SortingSession.unsorted else { return nil }
            for position in entry.position..<(entry.position + entry.count) {
                entries.append((position, entry.replaced))
            }
        }
        // Newest first: each decision's action is what the photo's next decision replaced.
        var actionAfter: [Int: SwipeAction?] = [:]
        var history: [SortDecision] = []
        history.reserveCapacity(entries.count)
        for entry in entries.reversed() {
            let id = assetIDs[entry.position]
            guard let action = actionAfter[entry.position] ?? decisions[id] else { return nil }
            let replaced = entry.replaced == SortingSession.unsorted ? nil : verdict(entry.replaced)
            actionAfter.updateValue(replaced?.action, forKey: entry.position)
            history.append(SortDecision(assetID: id, action: action, replaced: replaced))
        }
        return history.reversed()
    }

    private static func read(_ log: [UInt8], at start: Int) -> (position: Int, count: Int, replaced: UInt8) {
        let position = Int(log[start]) | Int(log[start + 1]) << 8 | Int(log[start + 2]) << 16 | Int(log[start + 3]) << 24
        let count = Int(log[start + 4]) | Int(log[start + 5]) << 8 | Int(log[start + 6]) << 16
        return (position, count, log[start + 7])
    }

    private static func write(position: Int, count: Int, replaced: UInt8, into log: inout [UInt8], at start: Int) {
        for byte in 0..<4 {
            log[start + byte] = UInt8(truncatingIfNeeded: position >> (8 * byte))
        }
        for byte in 0..<3 {
            log[start + 4 + byte] = UInt8(truncatingIfNeeded: count >> (8 * byte))
        }
        log[start + 7] = replaced
    }
}

/// A session's photo list, in a record of its own so that saving a decision doesn't write the
/// list out again.
@Model
final class SessionPhotos {
    /// The list, packed by `pack(_:)`; read and write it as `assetIDs`. SwiftData would store a
    /// `[String]` as a keyed archive, which for 50,000 photos (a large Recents, rewritten by every
    /// photo added to the library) takes about 0.2 s to save on the simulator; these bytes take
    /// under 0.05 s, packing included.
    var packedIDs = Data()
    var session: SortingSession?

    init(assetIDs: [String]) {
        self.packedIDs = Self.pack(assetIDs)
    }

    /// Image asset local identifiers, in session order (see `SortingSession.photos`). Every read
    /// unpacks the whole list, so read it once.
    var assetIDs: [String] {
        get { Self.unpack(packedIDs) }
        set { packedIDs = Self.pack(newValue) }
    }

    /// The identifiers' UTF-8 bytes, each preceded by its length (LEB128: one byte below 128, as
    /// PhotoKit's identifiers are). Unlike a separator, this holds any identifier.
    static func pack(_ ids: [String]) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(ids.reduce(ids.count) { $0 + $1.utf8.count })
        for id in ids {
            var length = id.utf8.count
            while length >= 0x80 {
                bytes.append(UInt8(truncatingIfNeeded: length) | 0x80)
                length >>= 7
            }
            bytes.append(UInt8(length))
            bytes.append(contentsOf: id.utf8)
        }
        return Data(bytes)
    }

    /// The identifiers `pack(_:)` packed into `data`. Damaged bytes end the list at the last
    /// whole identifier rather than trapping.
    static func unpack(_ data: Data) -> [String] {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var ids: [String] = []
            var index = 0
            while index < bytes.count {
                var length = 0
                var shift = 0
                var byte: UInt8
                repeat {
                    // An identifier is never anywhere near 2^28 bytes long.
                    guard index < bytes.count, shift < 28 else { return ids }
                    byte = bytes[index]
                    index += 1
                    length |= Int(byte & 0x7F) << shift
                    shift += 7
                } while byte & 0x80 != 0
                guard length <= bytes.count - index else { return ids }
                ids.append(String(decoding: UnsafeRawBufferPointer(rebasing: bytes[index..<(index + length)]), as: UTF8.self))
                index += length
            }
            return ids
        }
    }
}

/// Where an unfinished session picks up, shown as "Resume · 38 of 400": its first unsorted photo.
struct ResumePoint: Equatable, Sendable {
    let position: Int
    let total: Int
    let markedCount: Int
    let isComplete: Bool
}

extension ResumePoint {
    /// Where a session of `total` photos, `sorted` of them sorted and `marked` in the trash, picks
    /// up again: at its first unsorted photo, the one at `firstUnsortedIndex`. Nil when there is
    /// nothing worth resuming (never started, or everything sorted and the trash emptied).
    init?(total: Int, sorted: Int, marked: Int, firstUnsortedIndex: Int) {
        let isComplete = sorted >= total
        guard total > 0, sorted > 0 || marked > 0, !isComplete || marked > 0 else { return nil }
        self.init(position: min(firstUnsortedIndex + 1, total), total: total, markedCount: marked, isComplete: isComplete)
    }
}
