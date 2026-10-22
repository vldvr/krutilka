import Foundation

/// A saved combination of settings, offered as one segment on the tools wheel
/// ("For the web: WebP, 1920 px, no metadata").
struct Recipe: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable { case image, video }

    var id = UUID()
    var name: String
    var kind: Kind
    /// image: jpeg, png, heic, avif, webp. video: mp4, mov.
    var format: String
    /// Longest side in pixels, 0 keeps the size.
    var maxSide: Int
    var quality: Double
    var stripMetadata: Bool
    var enabled: Bool = true

    var summary: String {
        var parts = [format.uppercased()]
        if maxSide > 0 { parts.append("\(maxSide) px") }
        if kind == .image && format != "png" { parts.append("\(Int((quality * 100).rounded()))%") }
        if stripMetadata { parts.append(tr("no metadata")) }
        return parts.joined(separator: ", ")
    }

    static let defaults: [Recipe] = [
        Recipe(name: tr("For the web"), kind: .image, format: "webp", maxSide: 1920, quality: 0.8, stripMetadata: true),
        Recipe(name: tr("For email"), kind: .image, format: "jpeg", maxSide: 1600, quality: 0.75, stripMetadata: true),
        Recipe(name: tr("For chats"), kind: .video, format: "mp4", maxSide: 1280, quality: 0.7, stripMetadata: true),
    ]
}
