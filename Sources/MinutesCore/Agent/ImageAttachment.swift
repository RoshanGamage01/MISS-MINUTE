import Foundation

/// An image the model should see (usually a screenshot), base64-encoded.
public struct ImageAttachment: Codable, Sendable, Equatable {
    public var mediaType: String
    public var base64: String
    public var width: Int
    public var height: Int

    public init(mediaType: String = "image/jpeg", base64: String, width: Int, height: Int) {
        self.mediaType = mediaType
        self.base64 = base64
        self.width = width
        self.height = height
    }

    public init(jpeg: Data, width: Int, height: Int) {
        self.init(mediaType: "image/jpeg", base64: jpeg.base64EncodedString(), width: width, height: height)
    }

    public var dataURL: String { "data:\(mediaType);base64,\(base64)" }
}
