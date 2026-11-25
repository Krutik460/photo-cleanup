import Foundation

// Thresholds. Feature-print distances are Euclidean on unit vectors: 0 = identical, ~1.06 = a typical
// unrelated pair.
enum Tuning {
    static let duplicateDistance = 0.40  // same shot or an edit/export of it: group no matter when it was taken
    static let burstSeconds = 15.0, burstDistance = 0.70  // rapid-fire shots: allow blur and small movement
    static let sceneSeconds = 600.0, sceneDistance = 0.50  // same people, same pose, a few minutes apart
    static let maxGroupSpread = 0.80  // every pair inside a group must be at least this close (stops chaining)
    static let exactDuplicate = 0.06  // Vision feature prints jitter slightly, even for byte-identical files
    static let closeCallMargin = 0.04  // top-two score gap under this is flagged for a second opinion
    static let blurrySharpness = 15.0

    // Collections (trips, events, everyday months). All offline: GPS coordinates are never sent anywhere.
    static let momentGapHours = 3.0  // a pause this long between photos starts a new moment
    static let momentMaxKm = 25.0  // moving further than this starts a new moment
    static let awayKm = 50.0  // further than this from home counts as away
    static let tripMaxGapHours = 36.0  // away moments closer than this in time form one trip
    static let eventMinPhotos = 20  // a day at home with at least this many photos is an event
    static let homeGridDegrees = 0.1  // ~10 km cells for finding home

    // You: keep more of your photos, prune everything else harder.
    static let meRankBonus = 0.20  // in a mixed group, a shot of you beats a slightly better shot without you
    static let secondOfYouMargin = 0.10  // keep a second shot of you when it scores within this of the best one
    static let secondOfYouDistance = 0.30  // ...and is at least this different from it (not a near-copy)
    static let eventRepeatDistance = 0.45  // without you: near-repeats anywhere in one trip or event form a group
    static let lowQualityPercentile = 0.35  // singles without you scoring in the bottom 35% are suggested for removal
}

public enum CollectionKind: String, Codable, Sendable {
    case trip, daytrip, event, everyday
}

public enum PhotoState: String, Codable, Sendable {
    case fav, keep, remove
}

/// What grouping needs to know about a photo.
public struct GroupingPhoto: Sendable {
    public var id: String
    public var rel: String
    public var time: Double  // capture time when known, else the file's modification time
    public var timeKnown: Bool  // true when `time` is an EXIF capture time (a wall-clock value stored as if UTC)
    public var width: Int
    public var height: Int
    public var size: Int
    public var faceQualities: [Double?]  // one entry per detected face
    public var meFace: Int?  // which face matched you best, when any was compared
    public var aesthetic: Double?
    public var sharpness: Double
    public var utility: Bool
    public var gps: (lat: Double, lon: Double)?
    public var me: Bool
    /// The folder directly inside the photo folder that holds this photo (at any depth), nil for a
    /// photo that lies loose in the photo folder. Such a folder is a collection as it is.
    public var folder: String?

    public init(id: String, rel: String, time: Double, timeKnown: Bool, width: Int, height: Int, size: Int,
                faceQualities: [Double?] = [], meFace: Int? = nil, aesthetic: Double? = nil, sharpness: Double,
                utility: Bool = false, gps: (lat: Double, lon: Double)? = nil, me: Bool = false, folder: String? = nil) {
        self.id = id; self.rel = rel; self.time = time; self.timeKnown = timeKnown
        self.width = width; self.height = height; self.size = size
        self.faceQualities = faceQualities; self.meFace = meFace; self.aesthetic = aesthetic
        self.sharpness = sharpness; self.utility = utility; self.gps = gps; self.me = me
        self.folder = folder
    }
}

/// Your fixes to the detected collections. Every edit lists the photos of the collections it was made
/// on and applies to the collection holding most of them now, so it survives rescans and regrouping.
public struct GroupingEdits: Sendable {
    public var merges: [[[String]]] = []  // per merge, the photos of each part
    public var notCollections: [[String]] = []  // photos of a trip or event that is not really one
    public var moves: [(photos: [String], into: [String])] = []  // photos moved into the collection of `into`

    public init(merges: [[[String]]] = [], notCollections: [[String]] = [], moves: [(photos: [String], into: [String])] = []) {
        self.merges = merges; self.notCollections = notCollections; self.moves = moves
    }
}

/// A trip or event you marked as not one, as remembered by the everyday month that took its photos.
public struct FoldedNote: Sendable, Equatable {
    public var anchors: [String]  // one photo per mark, to restore it
    public var kind: CollectionKind
    public var start: Double
    public var end: Double
    public var timeKnown: Bool
    public var photos: Int
}

public struct GroupedCollection: Sendable {
    public var id: String
    public var kind: CollectionKind
    public var start: Double
    public var end: Double
    public var timeKnown: Bool
    public var days: Int
    public var center: [Double]?
    public var homeKm: Int?
    public var members: [String]
    public var parts: Int?  // set when it was merged from several collections
    public var folded: [FoldedNote]
    public var groups: [String]
    public var sourceFolder: String? = nil  // set when it is a folder of yours, taken as a collection
}

public enum GroupKind: String, Codable, Sendable {
    case duplicate, nearDuplicate = "near-duplicate", similar
}

public struct PhotoGroup: Sendable {
    public var id: String
    public var members: [String]  // best first
    public var kind: GroupKind
    public var close: Bool  // the two best are nearly tied
    public var you: Bool
    public var collection: String
}

public struct GroupedPhoto: Sendable {
    public var score: Double
    public var tags: [String]
    public var group: String?
    public var collection: String
    public var auto: PhotoState
    public var reason: String
}

public struct GroupingResult: Sendable {
    public var home: [Double]?
    public var collections: [GroupedCollection]
    public var groups: [PhotoGroup]
    public var photos: [String: GroupedPhoto]
    public var order: [String]  // all photos in time order
}

// MARK: - Ordering and rounding shared by the grouping code

/// Orders strings by Unicode scalar, so results do not depend on the locale or on normalization.
func scalarLess(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
}

/// Rounds to `digits` decimals, correctly for the stored binary value.
func rounded(_ x: Double, _ digits: Int) -> Double {
    Double(String(format: "%.\(digits)f", x)) ?? x
}

/// Great-circle distance in kilometres.
func km(_ a: (lat: Double, lon: Double), _ b: (lat: Double, lon: Double)) -> Double {
    let rad = Double.pi / 180
    let lat1 = a.lat * rad, lon1 = a.lon * rad, lat2 = b.lat * rad, lon2 = b.lon * rad
    let h = pow(sin((lat2 - lat1) / 2), 2) + cos(lat1) * cos(lat2) * pow(sin((lon2 - lon1) / 2), 2)
    return 6371 * 2 * asin(h.squareRoot())
}

func centroid(_ points: [(lat: Double, lon: Double)]) -> (lat: Double, lon: Double)? {
    guard !points.isEmpty else { return nil }
    let n = Double(points.count)
    return (points.reduce(0) { $0 + $1.lat } / n, points.reduce(0) { $0 + $1.lon } / n)
}
