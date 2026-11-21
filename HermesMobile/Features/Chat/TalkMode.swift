import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

struct TalkSilenceDetector {
    enum Verdict: Equatable {
        case keepListening
        case finished
        case nothingSaid
    }

    static let sampleInterval = Duration.milliseconds(100)

    var speechDecibels: Float = -40
    var endingSilence = Duration.milliseconds(1_300)
    var waitForSpeech = Duration.seconds(10)
    var longestTurn = Duration.seconds(90)

    private(set) var heardSpeech = false
    private var silence = Duration.zero
    private var elapsed = Duration.zero

    mutating func push(decibels: Float?, after interval: Duration = sampleInterval) -> Verdict {
        elapsed += interval
        if let decibels, decibels.isFinite, decibels > speechDecibels {
            heardSpeech = true
            silence = .zero
        } else {
            silence += interval
        }
        if heardSpeech {
            return silence >= endingSilence || elapsed >= longestTurn ? .finished : .keepListening
        }
        return elapsed >= waitForSpeech ? .nothingSaid : .keepListening
    }
}

@MainActor
@Observable
final class TalkModeController {
    enum Phase: Equatable {
        case idle
        case listening
        case transcribing
        case thinking
        case speaking
    }

    private(set) var phase: Phase = .idle
    private(set) var errorMessage: String?

    var isActive: Bool { phase != .idle }

    @ObservationIgnored var transcribe: ComposerTranscriber?
    @ObservationIgnored var send: (@MainActor (String) async -> Bool)?
    @ObservationIgnored var isReplyRunning: @MainActor () -> Bool = { false }
    @ObservationIgnored var speakLatestReply: @MainActor () -> Bool = { false }
    @ObservationIgnored var stopSpeaking: @MainActor () -> Void = {}

    @ObservationIgnored private let recorder: any ComposerServerRecording
    @ObservationIgnored private let microphonePermission: () async -> Bool
    @ObservationIgnored private let nextSample: @Sendable () async throws -> Void
    @ObservationIgnored private let readRecording: (URL) throws -> Data
    @ObservationIgnored private var listenTask: Task<Void, Never>?
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var generation = 0

    init(
        recorder: (any ComposerServerRecording)? = nil,
        microphonePermission: @escaping () async -> Bool = { await ComposerVoiceMicrophonePermissionRequester.request() },
        nextSample: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: TalkSilenceDetector.sampleInterval) },
        readRecording: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.recorder = recorder ?? ComposerServerAudioRecorder()
        self.microphonePermission = microphonePermission
        self.nextSample = nextSample
        self.readRecording = readRecording
    }

    func start() {
        guard phase == .idle else { return }
        errorMessage = nil
        generation += 1
        let started = generation
        phase = .listening
        listenTask = Task { [weak self] in
            guard let self else { return }
            guard await self.microphonePermission() else {
                guard self.generation == started else { return }
                self.finish(error: String(localized: "Talk needs access to the microphone."))
                return
            }
            guard self.generation == started else { return }
            await self.runListening(generation: started)
        }
    }

    func end() {
        finish(error: nil)
    }

    func dismissError() {
        errorMessage = nil
    }

    func interrupt() {
        guard phase == .speaking else { return }
        stopSpeaking()
    }

    func replyFinished() {
        guard phase == .thinking else { return }
        if speakLatestReply() {
            phase = .speaking
        } else {
            listen()
        }
    }

    func speakingFinished() {
        guard phase == .speaking else { return }
        listen()
    }

    private func listen() {
        generation += 1
        let started = generation
        phase = .listening
        listenTask = Task { [weak self] in
            await self?.runListening(generation: started)
        }
    }

    private func runListening(generation started: Int) async {
        do {
            recordingURL = try recorder.start()
        } catch {
            finish(error: String(localized: "Talk could not hear you. Try again."))
            return
        }
        var detector = TalkSilenceDetector()
        var verdict = TalkSilenceDetector.Verdict.keepListening
        while verdict == .keepListening {
            do { try await nextSample() } catch { return }
            guard generation == started, !Task.isCancelled else { return }
            verdict = detector.push(decibels: recorder.decibels)
        }
        recorder.stop()
        guard verdict == .finished, let url = recordingURL else {
            discardRecording()
            finish(error: nil)
            return
        }
        phase = .transcribing
        let audio = try? readRecording(url)
        discardRecording()
        guard let audio, let transcribe else {
            finish(error: String(localized: "Talk could not hear you. Try again."))
            return
        }
        let transcript: String
        do {
            let response = try await transcribe(audio, url.lastPathComponent)
            transcript = (response.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            guard generation == started, !Task.isCancelled else { return }
            finish(error: String(localized: "Talk could not hear you. Try again."))
            return
        }
        guard generation == started, !Task.isCancelled else { return }
        guard !transcript.isEmpty else {
            listen()
            return
        }
        await submit(transcript, generation: started)
    }

    private func submit(_ transcript: String, generation started: Int) async {
        guard let send else {
            finish(error: String(localized: "The message was not sent."))
            return
        }
        phase = .thinking
        let sent = await send(transcript)
        guard generation == started, phase == .thinking else { return }
        guard sent else {
            finish(error: String(localized: "The message was not sent."))
            return
        }
        if !isReplyRunning() { replyFinished() }
    }

    private func finish(error: String?) {
        generation += 1
        listenTask?.cancel()
        listenTask = nil
        recorder.stop()
        discardRecording()
        if phase == .speaking { stopSpeaking() }
        phase = .idle
        errorMessage = error
    }

    private func discardRecording() {
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
    }
}

struct TalkModeBar: View {
    let talk: TalkModeController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            Text(label)
                .font(AppFont.subheadline(weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if talk.phase == .speaking {
                Button(action: talk.interrupt) {
                    Text("Interrupt")
                        .font(AppFont.subheadline())
                }
                .buttonStyle(.bordered)
                .accessibilityHint(Text("Stops the reply and listens again"))
            }

            Button(action: talk.end) {
                Text("End Talk")
                    .font(AppFont.subheadline(weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Talk"))
    }

    private var label: String {
        switch talk.phase {
        case .idle, .listening: String(localized: "Listening...")
        case .transcribing: String(localized: "Transcribing...")
        case .thinking: String(localized: "Thinking...")
        case .speaking: String(localized: "Speaking...")
        }
    }

    private var symbol: String {
        switch talk.phase {
        case .idle, .listening: "mic.fill"
        case .transcribing, .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        }
    }
}
