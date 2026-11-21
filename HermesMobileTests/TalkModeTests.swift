import Observation
import XCTest
@testable import HermesMobile

@MainActor
final class TalkModeTests: XCTestCase {
    private var recorder: TalkFakeRecorder!
    private var sent: [String] = []
    private var spoken = 0
    private var stoppedSpeaking = 0

    override func setUp() {
        super.setUp()
        recorder = TalkFakeRecorder()
        sent = []
        spoken = 0
        stoppedSpeaking = 0
    }

    func testATurnSendsWhatWasSaidSpeaksTheReplyAndListensAgain() async {
        let talk = makeTalk(transcript: "What is on my calendar?")
        recorder.turns = [TalkFakeRecorder.spokenTurn]

        talk.start()
        await waitUntil("the transcript is sent") { talk.phase == .thinking }
        XCTAssertEqual(sent, ["What is on my calendar?"])

        talk.replyFinished()
        XCTAssertEqual(talk.phase, .speaking)
        XCTAssertEqual(spoken, 1)

        talk.speakingFinished()
        await waitUntil("the microphone opens again") { self.recorder.starts == 2 }
        XCTAssertEqual(talk.phase, .listening)

        talk.end()
        XCTAssertEqual(talk.phase, .idle)
        XCTAssertFalse(recorder.isRecording)
    }

    func testEndingWhileTheReplyIsSpokenStopsThePlayback() async {
        let talk = makeTalk(transcript: "Hello")
        recorder.turns = [TalkFakeRecorder.spokenTurn]
        talk.start()
        await waitUntil("the transcript is sent") { talk.phase == .thinking }
        talk.replyFinished()

        talk.end()

        XCTAssertEqual(stoppedSpeaking, 1)
        XCTAssertEqual(talk.phase, .idle)
    }

    func testAFailedTranscriptionSendsNothingAndSaysSo() async {
        let talk = makeTalk(transcript: nil)
        recorder.turns = [TalkFakeRecorder.spokenTurn]

        talk.start()
        await waitUntil("talk ends") { talk.phase == .idle }

        XCTAssertTrue(sent.isEmpty)
        XCTAssertNotNil(talk.errorMessage)
    }

    func testAMessageTheChatKeptEndsTalkWithAnError() async {
        let talk = makeTalk(transcript: "Hello", sends: false)
        recorder.turns = [TalkFakeRecorder.spokenTurn]

        talk.start()
        await waitUntil("talk ends") { talk.phase == .idle }

        XCTAssertEqual(sent, ["Hello"])
        XCTAssertNotNil(talk.errorMessage)
    }

    func testSilenceEndsTalkWithoutSending() async {
        let talk = makeTalk(transcript: "unused")
        recorder.turns = [Array(repeating: -90, count: 120)]

        talk.start()
        await waitUntil("talk ends") { talk.phase == .idle }

        XCTAssertTrue(sent.isEmpty)
        XCTAssertNil(talk.errorMessage)
    }

    private func makeTalk(transcript: String?, sends: Bool = true) -> TalkModeController {
        let recorder = recorder!
        let talk = TalkModeController(
            recorder: recorder,
            microphonePermission: { true },
            nextSample: { try await recorder.nextSample() },
            readRecording: { _ in Data([1, 2, 3]) }
        )
        talk.transcribe = { _, _ in
            guard let transcript else { throw URLError(.badServerResponse) }
            return TranscribeResponse(ok: true, transcript: transcript, error: nil)
        }
        talk.send = { [weak self] text in
            self?.sent.append(text)
            return sends
        }
        talk.isReplyRunning = { true }
        talk.speakLatestReply = { [weak self] in
            self?.spoken += 1
            return true
        }
        talk.stopSpeaking = { [weak self] in self?.stoppedSpeaking += 1 }
        return talk
    }
}

@MainActor
@Observable
private final class TalkFakeRecorder: ComposerServerRecording {
    static let spokenTurn: [Float] = Array(repeating: -20, count: 5) + Array(repeating: -90, count: 20)

    @ObservationIgnored var onFinish: (() -> Void)?
    var turns: [[Float]] = []
    private(set) var starts = 0
    private(set) var isRecording = false
    private var samples: [Float] = []
    private var current: Float?

    var decibels: Float? { current }

    func start() throws -> URL {
        starts += 1
        isRecording = true
        samples = turns.isEmpty ? [] : turns.removeFirst()
        return FileManager.default.temporaryDirectory.appendingPathComponent("talk-\(UUID().uuidString).m4a")
    }

    func stop() {
        isRecording = false
    }

    func nextSample() async throws {
        if !samples.isEmpty {
            current = samples.removeFirst()
            return
        }
        let parked = AsyncStream<Void> { _ in }
        for await _ in parked {}
        throw CancellationError()
    }
}
