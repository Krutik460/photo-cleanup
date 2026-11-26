import Foundation
import GRDB

public enum PhotoLocation: String, Codable, Sendable {
    case inPlace = "in_place"
    case filed
    case toRemove = "to_remove"
}

public enum MediaKind: String, Codable, Sendable {
    case photo, video
}

/// A photo or a video of the folder. Named for what most rows are.
public struct PhotoRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "photo"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var relPath: String
    public var originalRelPath: String
    public var fingerprint: String?
    public var size: Int
    public var mtime: Double
    public var taken: Double?
    public var width: Int
    public var height: Int
    public var aesthetic: Double?
    public var utility: Bool?
    public var sharpness: Double
    public var feature: Data?
    public var lat: Double?
    public var lon: Double?
    public var analysisVersion: Int
    public var error: String?
    public var location: PhotoLocation
    public var missing: Bool
    public var meSim: Double?
    public var meFace: Int?
    public var removedFromRel: String?
    public var media: MediaKind
    public var duration: Double?  // seconds, videos only

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct FaceRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "face"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var photoId: Int64
    public var idx: Int
    public var quality: Double?
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var crop: String?
    public var embedding: Data?
}
