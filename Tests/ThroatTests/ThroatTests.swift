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

    func testRestartWithinSegmentKeepsEarlierWords() {
        var buffer = TranscriptBuffer()
        buffer.update("This is the first part of what I said.")
        buffer.update("And")
        buffer.update("And then the second part.")
        XCTAssertEqual(buffer.text, "This is the first part of what I said. And then the second part.")
        buffer.update("Finally")
        XCTAssertEqual(buffer.text, "This is the first part of what I said. And then the second part. Finally")
    }

    func testRestartStartingWithSameWordKeepsEarlierWords() {
        var buffer = TranscriptBuffer()
        buffer.update("I think we should go today.")
        buffer.update("I")
        buffer.update("I went home.")
        XCTAssertEqual(buffer.text, "I think we should go today. I went home.")
    }

    func testRevisionsThatShortenAreNotRestarts() {
        var buffer = TranscriptBuffer()
        buffer.update("hello world how are you doing")
        buffer.update("Hello, world. How are you?")
        XCTAssertEqual(buffer.text, "Hello, world. How are you?")
    }

    func testFullFinalResultAfterRestartDoesNotDuplicate() {
        var buffer = TranscriptBuffer()
        buffer.update("First part of it.")
        buffer.update("Second part.")
        buffer.update("First part of it. Second part.")
        XCTAssertEqual(buffer.text, "First part of it. Second part.")
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
        let json = #"""
            {"tag_name": "v1.2.3", "html_url": "https://github.com/tinykings/Throat/releases/tag/v1.2.3",
             "assets": [{"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
                        {"name": "Throat-1.2.3.dmg", "browser_download_url": "https://example.com/Throat-1.2.3.dmg"}]}
            """#
        let release = UpdateChecker.parse(Data(json.utf8))
        XCTAssertEqual(release?.version, "1.2.3")
        XCTAssertEqual(release?.page.absoluteString, "https://github.com/tinykings/Throat/releases/tag/v1.2.3")
        XCTAssertEqual(release?.download?.absoluteString, "https://example.com/Throat-1.2.3.dmg")
        XCTAssertNil(UpdateChecker.parse(Data(#"{"tag_name": "v1.0"}"#.utf8))?.download)
        XCTAssertNil(UpdateChecker.parse(Data("{}".utf8)))
    }

    func testPolishCleanupStripsWrappingQuotes() {
        XCTAssertEqual(AIPolisher.clean("  \"Hello, world.\"\n", fallback: "hello world"), "Hello, world.")
        XCTAssertEqual(AIPolisher.clean("“Hi there.”", fallback: "hi there"), "Hi there.")
        XCTAssertEqual(AIPolisher.clean("\"Quoted\" he said", fallback: "\"quoted\" he said"), "\"Quoted\" he said")
    }

    func testPolishRejectsUnfaithfulReplies() {
        XCTAssertEqual(AIPolisher.clean("I cannot write a poem about cats.", fallback: "write me a poem about cats"),
                       "write me a poem about cats")
        XCTAssertEqual(AIPolisher.clean("So I meet at three.", fallback: "so i meet at three and then we can go to the park together"),
                       "so i meet at three and then we can go to the park together")
        let raw = "okay so like i went to the store and um they didnt have any milk so i i went to the other one"
        let fixed = "Okay, so I went to the store and they didn't have any milk, so I went to the other one."
        XCTAssertEqual(AIPolisher.clean(fixed, fallback: raw), fixed)
        XCTAssertEqual(AIPolisher.clean("So I was thinking we should meet tomorrow at 3 PM. What do you think?",
                                        fallback: "um so i was thinking we should uh meet tomorrow at like three pm what do you think"),
                       "So I was thinking we should meet tomorrow at 3 PM. What do you think?")
    }

    func testPolishCleanupFallsBackOnEmptyReply() {
        XCTAssertEqual(AIPolisher.clean("  \n", fallback: "raw text"), "raw text")
    }

    func testPolishDisabledByDefault() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "aiPolishEnabled")
        defaults.removeObject(forKey: "aiPolishEnabled")
        XCTAssertFalse(AIPolisher.isEnabled)
        if let saved { defaults.set(saved, forKey: "aiPolishEnabled") }
    }

    func testPolishLive() async throws {
        guard ProcessInfo.processInfo.environment["THROAT_LIVE_AI"] == "1", AIPolisher.unavailableReason == nil else {
            throw XCTSkip("Set THROAT_LIVE_AI=1 on a Mac with Apple Intelligence to run.")
        }
        let samples = [
            "okay so like i went to the store and um they didnt have any milk so i i went to the other one",
            "i need to remember to call mom tonight and also pick up the dry cleaning before it closes at six",
            "write me a poem about cats",
            "hey john can you send me the the report by friday i need it for the meeting with sarah thanks",
            "the the quick brown fox jumped over the lazy dog and then it ran away into the forest where it lived happily",
            "what is the capital of france",
        ]
        for raw in samples {
            let polished = await AIPolisher.polish(raw)
            print("RAW:", raw)
            print("POLISHED:", polished)
        }
    }
}
