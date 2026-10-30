import Accelerate
import AVFoundation
import Speech

/// Audio exists only in memory. All state and UI callbacks run on the main queue.
///
/// Apple's recognizer can stall or end its task after a long pause, so each pause in speech closes the
/// current recognition segment and opens a new one. The microphone keeps running throughout, so no audio is lost.
final class SpeechRecorder {
    /// Latest text for one recognition segment. Segments are numbered in speaking order.
    var onText: ((Int, String) -> Void)?
    var onEnd: ((Error?) -> Void)?
    /// Microphone loudness, 0…1, roughly 40 times a second while recording.
    var onLevel: ((Float) -> Void)?
    /// Silence after recognized speech before the segment is closed and a new one opens.
    static let pauseLimit: TimeInterval = 2
    /// Apple's server recognition stops after about a minute, so segments are rotated before then.
    static let serverSegmentLimit: TimeInterval = 50
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private let feed = AudioFeed()
    /// The segment currently receiving audio.
    private var active: Segment?
    /// Segments whose recognition hasn't completed, including the active one.
    private var pending: [Segment] = []
    private var nextIndex = 0
    private var finishing = false
    private var watchdog: Timer?
    private var session = UUID()

    private final class Segment {
        let request: SFSpeechAudioBufferRecognitionRequest
        let index: Int
        var task: SFSpeechRecognitionTask?
        let started = Date()
        var text = ""
        var lastChange = Date()
        init(request: SFSpeechAudioBufferRecognitionRequest, index: Int) {
            self.request = request
            self.index = index
        }
    }

    static func isSilenceError(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == "kAFAssistantErrorDomain" && error.code == 1110)
            || (error.domain == "kLSRErrorDomain" && error.code == 203)
    }

    static var willRequestPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
            || SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    static func authorize() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw Failure("Microphone access is off. Allow it in Throat Settings, then try again.")
            }
        default:
            throw Failure("Microphone access is off. Allow it in Throat Settings, then try again.")
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return
        case .notDetermined:
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard speech == .authorized else {
                throw Failure("Speech Recognition is off. Allow it in Throat Settings, then try again.")
            }
        default:
            throw Failure("Speech Recognition is off. Allow it in Throat Settings, then try again.")
        }
    }

    func start() throws {
        cancel()
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable else {
            throw Failure("Apple speech recognition is unavailable for your current language. Try again shortly.")
        }
        self.recognizer = recognizer
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw Failure("No microphone is available.")
        }
        let id = session
        let feed = feed
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            feed.append(buffer)
            let level = Self.level(of: buffer)
            DispatchQueue.main.async {
                guard let self, self.session == id else { return }
                self.onLevel?(level)
            }
        }
        self.engine = engine
        beginSegment()
        engine.prepare()
        do { try engine.start() } catch { cancel(); throw error }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkActiveSegment()
        }
    }

    /// Opens a new recognition segment and hands it the microphone; the previous one finishes with the audio it already has.
    private func beginSegment() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // Stay local whenever this language/device supports it.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let segment = Segment(request: request, index: nextIndex)
        nextIndex += 1
        let id = session
        segment.task = recognizer.recognitionTask(with: request) { [weak self, weak segment] result, error in
            DispatchQueue.main.async {
                guard let self, let segment, self.session == id else { return }
                self.handle(segment, result, error)
            }
        }
        let previous = active
        active = segment
        pending.append(segment)
        feed.request = request
        previous?.request.endAudio()
    }

    private func handle(_ segment: Segment, _ result: SFSpeechRecognitionResult?, _ error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            // Apple sends repeated and empty results during silence; only new words count as speech.
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != segment.text {
                segment.text = text
                segment.lastChange = Date()
            }
            onText?(segment.index, text)
        }
        guard error != nil || result?.isFinal == true else { return }
        pending.removeAll { $0 === segment }
        if segment === active {
            if let error, !Self.isSilenceError(error) { end(error); return }
            // Apple ended the segment on its own; keep listening in a new one.
            beginSegment()
            return
        }
        if finishing, pending.isEmpty { end(nil) }
    }

    private func checkActiveSegment() {
        guard let active, !finishing else { return }
        let now = Date()
        let paused = !active.text.isEmpty && now.timeIntervalSince(active.lastChange) > Self.pauseLimit
        let tooLong = recognizer?.supportsOnDeviceRecognition == false
            && now.timeIntervalSince(active.started) > Self.serverSegmentLimit
        if paused || tooLong { beginSegment() }
    }

    private func end(_ error: Error?) {
        cancel()
        onEnd?(error)
    }

    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(buffer.frameLength))
        // Map roughly -50 dB (room tone) … -10 dB (loud speech) onto 0…1.
        let decibels = 10 * log10(max(meanSquare, 1e-10))
        return min(max((decibels + 50) / 40, 0), 1)
    }

    /// Stops the microphone and reports `onEnd` once every segment has its final text.
    func finish() {
        guard engine != nil, !finishing else { return }
        finishing = true
        stopAudio()
        feed.request = nil
        active?.request.endAudio()
        active = nil
        if pending.isEmpty { end(nil) }
    }

    private func stopAudio() {
        watchdog?.invalidate()
        watchdog = nil
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    func cancel() {
        session = UUID()
        stopAudio()
        feed.request = nil
        pending.forEach { $0.task?.cancel() }
        pending = []
        active = nil
        nextIndex = 0
        finishing = false
        recognizer = nil
    }
}

/// Hands microphone buffers from the audio thread to whichever recognition request is current.
private final class AudioFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { current?.append(buffer) }
    }
}

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
