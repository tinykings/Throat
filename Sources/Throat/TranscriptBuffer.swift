import Foundation

/// Apple revises partial results within a segment, so each segment's latest text replaces its previous text.
/// Segments are joined in speaking order, even when an earlier segment's final result arrives late.
///
/// On-device recognition can also restart its transcript after a short pause without ending the segment:
/// the next result holds only the new words. Those restarts keep the earlier words instead of replacing them.
struct TranscriptBuffer {
    private struct Segment {
        /// Utterances Apple has already dropped from its results.
        var committed: [String] = []
        var current = ""
        var text: String { (committed + [current]).filter { !$0.isEmpty }.joined(separator: " ") }
    }

    private var segments: [Int: Segment] = [:]

    var text: String {
        segments.keys.sorted().compactMap { segments[$0]?.text }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    mutating func update(_ result: String, segment index: Int = 0) {
        let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty callbacks during silence must not erase the last useful hypothesis.
        guard !result.isEmpty else { return }
        var segment = segments[index] ?? Segment()
        let words = Self.words(result)
        if !segment.committed.isEmpty, words.starts(with: Self.words(segment.committed.joined(separator: " "))) {
            // A result covering the whole segment again (such as a final result) replaces the pieces.
            segment.committed = []
        } else if Self.isRestart(from: Self.words(segment.current), to: words) {
            segment.committed.append(segment.current)
        }
        segment.current = result
        segments[index] = segment
    }

    /// A revision keeps the opening words and roughly the same length; a restart is shorter and
    /// begins differently, or drops most of the words.
    static func isRestart(from old: [String], to new: [String]) -> Bool {
        guard !old.isEmpty, new.count < old.count else { return false }
        let shared = zip(old, new).prefix { $0 == $1 }.count
        return shared < min(new.count, 3) || (old.count >= 4 && new.count * 2 < old.count)
    }

    /// Lowercased words without punctuation, so added commas or capitals still count as the same words.
    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
