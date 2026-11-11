import AVFoundation
import Combine
import HuaciCore

/// Pronunciation through the system speech voices.
@MainActor
final class Speech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synthesizer: AVSpeechSynthesizer
    @Published private var utterance: AVSpeechUtterance?
    private var language: String?

    init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()
        synthesizer.delegate = self
    }

    func isSpeaking(_ result: TranslationResult) -> Bool {
        utterance?.speechString == (result.word?.headword ?? result.sourceText) && language == result.sourceLanguage
    }

    func toggle(_ result: TranslationResult) {
        if isSpeaking(result) { stop() } else {
            speak(result.word?.headword ?? result.sourceText, language: result.sourceLanguage)
        }
    }

    func speak(_ text: String, language: String?) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: language)
        self.language = language
        self.utterance = utterance
        synthesizer.speak(utterance)
    }

    func stop() {
        utterance = nil
        language = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finished(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finished(utterance)
    }

    private nonisolated func finished(_ utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.utterance = nil
            self.language = nil
        }
    }

    static func voice(for language: String?) -> AVSpeechSynthesisVoice? {
        guard let language else { return nil }
        let preferred: [String: String] = ["en": "en-US", "zh": "zh-CN", "zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "ja": "ja-JP", "ko": "ko-KR"]
        if let code = preferred[language], let voice = AVSpeechSynthesisVoice(language: code) { return voice }
        if let voice = AVSpeechSynthesisVoice(language: language) { return voice }
        let prefix = language.split(separator: "-").first.map(String.init) ?? language
        return AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix(prefix) }
    }
}
