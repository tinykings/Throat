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

    func testMissingPasteTargetIsRejected() {
        var error: String?
        PasteService.paste("Do not paste this", into: nil) { error = $0 }
        XCTAssertNotNil(error)
    }

    func testSelfPasteIsRejected() {
        var error: String?
        PasteService.paste("Do not paste this", into: .current) { error = $0 }
        XCTAssertNotNil(error)
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
}
