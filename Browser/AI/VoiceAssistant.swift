import AVFoundation
import Combine
import Speech
import SwiftUI

/// A one-tap action from the toolbar's AI menu, carried out by the assistant panel.
struct AIQuickRequest: Identifiable, Equatable {
    enum Action: Equatable {
        case summarize
        case explainSelection
        /// A question about the page; nil opens the panel ready to type.
        case ask(String?)
        /// A job for the agent; nil opens the panel ready to type.
        case task(String?)
        /// Said out loud with Talk: answered or run as a task, then read aloud.
        case spoken(String)
    }

    let id = UUID()
    let action: Action
}

/// Dictation for the assistant: listens until you pause, then hands back what you said.
/// Recognition stays on the device when the language supports it.
@MainActor
final class VoiceInput: ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var onFinish: ((String) -> Void)?

    /// How long a pause ends the request, and how long to wait for the first word.
    private static let pause: Duration = .seconds(1.6)
    private static let firstWordTimeout: Duration = .seconds(7)

    var isListening: Bool { state == .listening }

    func start(onFinish: @escaping (String) -> Void) async {
        cancel()
        transcript = ""
        guard await Self.requestPermissions() else {
            state = .unavailable("Allow Microphone and Speech Recognition for Vortyra in the Settings app to talk to the assistant.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            state = .unavailable("Speech recognition isn't available right now.")
            return
        }

        ReadAloud.shared.stop()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tapBlock(for: request))
            engine.prepare()
            try engine.start()
        } catch {
            tearDown()
            state = .unavailable("The microphone couldn't start. Try again in a moment.")
            return
        }

        self.onFinish = onFinish
        recognition = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(for: self))
        state = .listening
        scheduleStop(after: Self.firstWordTimeout)
    }

    /// Stops listening and sends what was heard so far.
    func finish() {
        guard isListening else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let deliver = onFinish
        tearDown()
        state = .idle
        if !text.isEmpty { deliver?(text) }
    }

    /// Stops listening and throws away what was heard.
    func cancel() {
        tearDown()
        state = .idle
    }

    func dismissMessage() {
        if case .unavailable = state { state = .idle }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard isListening else { return }
        if let text, !text.isEmpty, text != transcript {
            transcript = text
            scheduleStop(after: Self.pause)
        }
        if isFinal || failed {
            if transcript.isEmpty, failed {
                tearDown()
                state = .unavailable("Didn't catch that. Tap Talk and try again.")
            } else {
                finish()
            }
        }
    }

    private func scheduleStop(after delay: Duration) {
        silenceTimer?.cancel()
        silenceTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func tearDown() {
        silenceTimer?.cancel()
        silenceTimer = nil
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognition?.cancel()
        request = nil
        recognition = nil
        onFinish = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Audio and recognition callbacks arrive off the main thread.

    private nonisolated static func tapBlock(for request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    private nonisolated static func resultHandler(for voice: VoiceInput) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak voice] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak voice] in
                voice?.handle(text: text, isFinal: isFinal, failed: failed)
            }
        }
    }

    private nonisolated static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Reads assistant answers aloud after a spoken request.
@MainActor
final class ReadAloud: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = ReadAloud()

    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let spoken = Self.plainText(text)
        guard !spoken.isEmpty else { return }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        guard synthesizer.isSpeaking || isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        finished()
    }

    private func finished() {
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    /// Markdown answers read as plain sentences: no symbols, links read by their text.
    static func plainText(_ markdown: String) -> String {
        var text = markdown
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}|[-*+]|>)\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`~]+"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The floating bar while Talk is listening or an answer is being read aloud.
struct VoiceAssistantBar: View {
    @ObservedObject var voice: VoiceInput
    @ObservedObject var reader: ReadAloud

    @State private var pulse = false

    var body: some View {
        Group {
            switch voice.state {
            case .listening:
                listening
            case .unavailable(let message):
                notice(message)
            case .idle:
                if reader.isSpeaking { speaking }
            }
        }
        .animation(.easeOut(duration: 0.2), value: voice.state)
        .animation(.easeOut(duration: 0.2), value: reader.isSpeaking)
    }

    private var listening: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.red))
                .scaleEffect(pulse ? 1.08 : 0.94)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                }
                .onDisappear { pulse = false }
            Text(voice.transcript.isEmpty ? "Listening… ask about this page or give a task" : voice.transcript)
                .font(.subheadline)
                .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel", systemImage: "xmark") { voice.cancel() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            Button("Done", systemImage: "arrow.up.circle.fill") { voice.finish() }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.borderless)
                .disabled(voice.transcript.isEmpty)
        }
        .modifier(VoiceBarBackground())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Listening")
    }

    private var speaking: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.tint)
            Text("Reading the answer")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Stop") { reader.stop() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .modifier(VoiceBarBackground())
    }

    private func notice(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("OK") { voice.dismissMessage() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .modifier(VoiceBarBackground())
        .task {
            try? await Task.sleep(for: .seconds(6))
            voice.dismissMessage()
        }
    }
}

private struct VoiceBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
