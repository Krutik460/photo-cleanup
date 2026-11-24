import CoreGraphics
import CoreML
import Foundation

/// ArcFace (w600k_r50) as a compiled Core ML model, made by scripts/convert_face_model.py.
/// Takes an aligned 112x112 face crop and returns a unit-length 512-float identity embedding, so the
/// similarity of two faces is the dot product of their embeddings.
public final class CoreMLFaceEmbedder: FaceEmbedder, @unchecked Sendable {
    public static let dimensions = 512
    private let model: MLModel
    private let lock = NSLock()  // an MLModel serves one prediction at a time

    public init(compiledModelAt url: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)
    }

    public func embed(_ crop: CGImage) throws -> [Float] {
        let n = faceCropSize
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: crop.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = crop.width == n && crop.height == n ? .none : .high
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "cannot read the face crop"]) }

        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: n), NSNumber(value: n)], dataType: .float32)
        input.withUnsafeMutableBufferPointer(ofType: Float32.self) { p, _ in
            for i in 0..<(n * n) {
                for c in 0..<3 { p[c * n * n + i] = (Float(rgba[i * 4 + c]) - 127.5) / 127.5 }
            }
        }
        lock.lock()
        defer { lock.unlock() }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["face": input]))
        guard let e = output.featureValue(for: "embedding")?.multiArrayValue, e.count == Self.dimensions, e.dataType == .float32 else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "unexpected face model output"])
        }
        var v = e.withUnsafeBufferPointer(ofType: Float32.self) { Array($0) }
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 0 { for i in v.indices { v[i] /= norm } }
        return v
    }
}
