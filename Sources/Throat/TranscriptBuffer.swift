import Foundation

/// Apple revises partial results within a segment, so each segment's latest text replaces its previous text.
/// Segments are joined in speaking order, even when an earlier segment's final result arrives late.
struct TranscriptBuffer {
    private var segments: [Int: String] = [:]

    var text: String {
        segments.keys.sorted().compactMap { segments[$0] }.joined(separator: " ")
    }

    mutating func update(_ result: String, segment: Int = 0) {
        let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty callbacks during silence must not erase the last useful hypothesis.
        if !result.isEmpty { segments[segment] = result }
    }
}
