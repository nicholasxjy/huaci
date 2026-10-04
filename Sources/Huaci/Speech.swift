import AVFoundation

/// Pronunciation through the system speech voices.
@MainActor
final class Speech {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, language: String?) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: language)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
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
