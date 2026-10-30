import XCTest
import Carbon
@testable import Throat

final class ThroatTests: XCTestCase {
    func testDefaultShortcutIsOptionSpace() {
        XCTAssertEqual(Shortcut.standard.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(Shortcut.standard.modifiers, UInt32(optionKey))
        XCTAssertEqual(Shortcut.standard.label, "⌥Space")
    }

    func testShortcutRoundTrip() throws {
        let shortcut = Shortcut(keyCode: 12, modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘Q")
        let decoded = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(shortcut))
        XCTAssertEqual(decoded.keyCode, shortcut.keyCode)
        XCTAssertEqual(decoded.modifiers, shortcut.modifiers)
        XCTAssertEqual(decoded.label, shortcut.label)
    }

    func testMissingPasteTargetIsOnlyCopied() {
        var outcome: PasteOutcome?
        PasteService.paste("Do not paste this", into: nil) { outcome = $0 }
        XCTAssertEqual(outcome, .copied)
    }

    func testSelfPasteIsNotPasted() {
        var outcome: PasteOutcome?
        PasteService.paste("Do not paste this", into: .current) { outcome = $0 }
        XCTAssertNotNil(outcome)
        XCTAssertNotEqual(outcome, .pasted)
    }

    func testSilenceDoesNotClearTranscript() {
        var buffer = TranscriptBuffer()
        buffer.update("Keep these words.")
        buffer.update("")
        buffer.update("  \n ")
        XCTAssertEqual(buffer.text, "Keep these words.")
    }

    func testSegmentsAccumulateAcrossPauses() {
        var buffer = TranscriptBuffer()
        buffer.update("First sentence.", segment: 0)
        buffer.update("", segment: 1)
        XCTAssertEqual(buffer.text, "First sentence.")
        buffer.update("Second", segment: 1)
        buffer.update("Second sentence.", segment: 1)
        XCTAssertEqual(buffer.text, "First sentence. Second sentence.")
    }

    func testLateFinalResultKeepsSpeakingOrder() {
        var buffer = TranscriptBuffer()
        buffer.update("First", segment: 0)
        buffer.update("Second sentence.", segment: 1)
        buffer.update("First sentence.", segment: 0)
        XCTAssertEqual(buffer.text, "First sentence. Second sentence.")
    }

    func testPartialRevisionsReplaceInsteadOfDuplicate() {
        var buffer = TranscriptBuffer()
        buffer.update("Hello")
        buffer.update("Hello world.")
        XCTAssertEqual(buffer.text, "Hello world.")
    }

    func testOnlyNoSpeechErrorsAreRestartable() {
        XCTAssertTrue(SpeechRecorder.isSilenceError(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
        XCTAssertTrue(SpeechRecorder.isSilenceError(NSError(domain: "kLSRErrorDomain", code: 203)))
        XCTAssertFalse(SpeechRecorder.isSilenceError(NSError(domain: "network", code: 1110)))
        XCTAssertFalse(SpeechRecorder.isSilenceError(NSError(domain: "kAFAssistantErrorDomain", code: 1101)))
    }

    func testRecorderCanBeCancelledBeforeStarting() {
        let recorder = SpeechRecorder()
        recorder.cancel()
        recorder.finish()
        recorder.cancel()
    }

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
    }

    func testParsesReleaseTag() {
        let json = #"{"tag_name": "v1.2.3", "html_url": "https://github.com/tinykings/Throat/releases/tag/v1.2.3"}"#
        let release = UpdateChecker.parse(Data(json.utf8))
        XCTAssertEqual(release?.version, "1.2.3")
        XCTAssertEqual(release?.page.absoluteString, "https://github.com/tinykings/Throat/releases/tag/v1.2.3")
        XCTAssertNil(UpdateChecker.parse(Data("{}".utf8)))
    }
}
