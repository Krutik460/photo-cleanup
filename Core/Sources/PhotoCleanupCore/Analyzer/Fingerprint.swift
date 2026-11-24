import CryptoKit
import Foundation

/// A cheap content fingerprint: the file size plus a hash of its first and last 64 KB. It lets a scan
/// recognise a photo that was moved or renamed outside the app without reading whole files from a
/// slow drive. Byte-identical copies share a fingerprint by design.
public func fingerprint(of url: URL) -> String? {
    let chunk = 64 * 1024
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    var hash = SHA256()
    withUnsafeBytes(of: size.littleEndian) { hash.update(bufferPointer: $0) }
    do {
        try handle.seek(toOffset: 0)
        hash.update(data: try handle.read(upToCount: chunk) ?? Data())
        if size > UInt64(chunk) {
            try handle.seek(toOffset: max(UInt64(chunk), size - UInt64(chunk)))
            hash.update(data: try handle.read(upToCount: chunk) ?? Data())
        }
    } catch {
        return nil
    }
    return hash.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
}
