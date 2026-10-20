import Foundation
import SwiftData

/// One persisted sorting session per album, so sorting can be resumed after quitting.
///
/// Piq saves after every decision, so a decision writes as little as it can: the photo list, which
/// runs to tens of thousands of identifiers in a large Recents, is a record of its own
/// (`SessionPhotos`) that only a library change or a fresh start rewrites, and the decisions take
/// one byte per sorted photo. (SQLite rewrites a whole row when any of its fields changes.)
@Model
final class SortingSession {
    /// `PHAssetCollection.localIdentifier` of the album being sorted.
    @Attribute(.unique) var albumID: String
    var albumTitle: String
    /// The photos in session order: the sorted ones in the order they were sorted, then the rest
    /// oldest first.
    @Relationship(deleteRule: .cascade, inverse: \SessionPhotos.session) var photos: SessionPhotos?
    /// How many photos `photos` holds, so the picker's "Resume · 38 of 400" doesn't read the list.
    var photoCount: Int = 0
    /// One byte per sorted photo, in session order: the letter of its decision ("k" keep, "d"
    /// delete), in upper case while the photo is in Piq's trash. "kDkd" is a keep, a photo marked
    /// for deletion, a keep, and a photo marked for deletion and then restored.
    var decisions = Data()
    var createdAt: Date
    /// When the person last worked on the session: opened it, sorted, restored photos or emptied
    /// the trash. The picker preselects the most recent unfinished session on launch, so changes
    /// the library makes (photos added or deleted elsewhere, the album renamed) don't count.
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
        get { Self.decode(assetIDs: photos?.assetIDs ?? [], decisions: decisions) }
        set { write(newValue, over: state, touch: false) }
    }

    /// Writes the fields of `state` that differ from `old`, the state the record holds now,
    /// without reading the stored photo list: a session controller keeps its state in memory and
    /// saves its changes this way (decisions and undos the quicker way below). `touch` is for a
    /// change the person made, which makes this the session they worked on last.
    ///
    /// Afterwards `decisions` holds exactly one letter per sorted photo, even if it held more
    /// (see `recordDecision(_:at:inTrash:)`).
    func write(_ state: SortingState, over old: SortingState, touch: Bool) {
        if state.assetIDs != old.assetIDs {
            setPhotoList(state.assetIDs)
        }
        if state.history != old.history || state.markedIDs != old.markedIDs || decisions.count != state.sortedCount {
            decisions = Self.encode(state)
        }
        if touch {
            updatedAt = .now
        }
    }

    /// Records the decision `SortingState.apply(_:)` just made for the photo at `index` (the
    /// number of photos sorted before it) as its letter. Sorting's hot path: `write(_:over:touch:)`
    /// would go through the whole undo history and trash to find that out, which 29,000 photos
    /// into a session costs more than the save.
    ///
    /// Letters from `index` on give way, so the record holds exactly one letter per sorted photo
    /// even if it held more (written by another build, or damaged): `state` reads at most one per
    /// photo, and a stale one left behind would come back once the photo list grew.
    func recordDecision(_ action: SwipeAction, at index: Int, inTrash: Bool) {
        var letters = decisions.prefix(index)
        letters.append(Self.byte(for: action, inTrash: inTrash))
        decisions = letters
        updatedAt = .now
    }

    /// Keeps the first `count` decisions only, as after `SortingState.undo()`.
    func keepDecisions(_ count: Int) {
        decisions = decisions.prefix(count)
        updatedAt = .now
    }

    /// Where to pick up again, or nil when there is nothing worth resuming (never started, or
    /// everything sorted and the trash emptied).
    var resumePoint: ResumePoint? {
        let sorted = decisions.prefix(photoCount)
        let marked = sorted.reduce(0) { $0 + (Self.isInTrash($1) ? 1 : 0) }
        return ResumePoint(total: photoCount, sorted: sorted.count, marked: marked)
    }

    /// Starts over with a fresh list of photos.
    func reset(assetIDs: [String], albumTitle: String) {
        self.albumTitle = albumTitle
        setPhotoList(SortingState(assetIDs: assetIDs).assetIDs)
        decisions = Data()
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

    /// The state that `assetIDs` and `decisions` describe. A letter this build doesn't know (one
    /// written by a later build) counts as a delete if the photo is in the trash, else as a keep.
    static func decode(assetIDs: [String], decisions: Data) -> SortingState {
        var history: [SortDecision] = []
        var marked: [String] = []
        history.reserveCapacity(min(assetIDs.count, decisions.count))
        for (assetID, byte) in zip(assetIDs, decisions) {
            let inTrash = isInTrash(byte)
            let action = action(forLetter: byte | lowercaseBit) ?? (inTrash ? .delete : .keep)
            history.append(SortDecision(assetID: assetID, action: action))
            if inTrash {
                marked.append(assetID)
            }
        }
        return SortingState(assetIDs: assetIDs, currentIndex: history.count, markedIDs: marked, history: history)
    }

    /// `decisions` for `state`.
    static func encode(_ state: SortingState) -> Data {
        Data(state.history.map { byte(for: $0.action, inTrash: state.isMarked($0.assetID)) })
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
        decisions = Self.encode(state)
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

/// Where an unfinished session left off, shown as "Resume · 38 of 400".
struct ResumePoint: Equatable, Sendable {
    let position: Int
    let total: Int
    let markedCount: Int
    let isComplete: Bool
}

extension ResumePoint {
    /// Where a session of `total` photos, `sorted` of them sorted and `marked` in the trash,
    /// picks up again; nil when there is nothing worth resuming (never started, or everything
    /// sorted and the trash emptied).
    init?(total: Int, sorted: Int, marked: Int) {
        let isComplete = sorted >= total
        guard total > 0, sorted > 0 || marked > 0, !isComplete || marked > 0 else { return nil }
        self.init(position: min(sorted + 1, total), total: total, markedCount: marked, isComplete: isComplete)
    }
}
