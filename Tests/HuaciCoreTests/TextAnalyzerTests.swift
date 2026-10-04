import Testing
@testable import HuaciCore

struct TextAnalyzerTests {
    let rules = LanguageRules()

    @Test(arguments: ["", "   \n\t", "12345", "—…!?", "  42.0 "])
    func rejectsTextWithoutLetters(_ input: String) {
        #expect(TextAnalyzer.analyze(input, rules: rules) == nil)
    }

    @Test func englishWordGoesToChinese() throws {
        let analysis = try #require(TextAnalyzer.analyze("  serendipity\n", rules: rules))
        #expect(analysis.text == "serendipity")
        #expect(analysis.kind == .word)
        #expect(!analysis.isChinese)
        #expect(analysis.sourceLanguage == "en")
        #expect(analysis.targetLanguage == "zh-Hans")
    }

    @Test(arguments: ["take off", "in spite of", "New York", "U.S.", "e.g.", "don't"])
    func shortPhrasesAreDictionaryLookups(_ input: String) throws {
        #expect(try #require(TextAnalyzer.analyze(input, rules: rules)).kind == .word)
    }

    @Test(arguments: [
        "The quick brown fox jumps over the lazy dog.",
        "Hello, world",
        "Is it raining?",
        "first line\nsecond line",
    ])
    func sentencesAreTranslations(_ input: String) throws {
        #expect(try #require(TextAnalyzer.analyze(input, rules: rules)).kind == .text)
    }

    @Test func chineseWordGoesToEnglish() throws {
        let analysis = try #require(TextAnalyzer.analyze("人工智能", rules: rules))
        #expect(analysis.isChinese)
        #expect(analysis.kind == .word)
        #expect(analysis.targetLanguage == "en")
    }

    @Test func chineseSentenceIsText() throws {
        let analysis = try #require(TextAnalyzer.analyze("今天天气很好，我们去公园散步吧。", rules: rules))
        #expect(analysis.kind == .text)
        #expect(analysis.targetLanguage == "en")
    }

    @Test func mixedChineseWithEnglishTermsCountsAsChinese() throws {
        let analysis = try #require(TextAnalyzer.analyze("我今天用了 React hooks 重构组件", rules: rules))
        #expect(analysis.isChinese)
        #expect(analysis.kind == .text)
    }

    @Test func englishSentenceWithChineseNameCountsAsForeign() throws {
        let analysis = try #require(TextAnalyzer.analyze("We had dinner at 北京 with some old friends from school.", rules: rules))
        #expect(!analysis.isChinese)
        #expect(analysis.targetLanguage == "zh-Hans")
    }

    @Test func japaneseWithKanjiIsNotChinese() throws {
        let analysis = try #require(TextAnalyzer.analyze("今日はとても良い天気ですね。", rules: rules))
        #expect(!analysis.isChinese)
        #expect(analysis.sourceLanguage == "ja")
        #expect(analysis.targetLanguage == "zh-Hans")
    }

    @Test func frenchSentenceIsDetected() throws {
        let analysis = try #require(TextAnalyzer.analyze("Je voudrais réserver une table pour deux personnes ce soir.", rules: rules))
        #expect(analysis.sourceLanguage == "fr")
        #expect(analysis.kind == .text)
    }

    @Test func paragraphsKeepTheirBreaks() throws {
        let input = "First paragraph here.\r\n\r\nSecond paragraph here.\n"
        let analysis = try #require(TextAnalyzer.analyze(input, rules: rules))
        #expect(analysis.text == "First paragraph here.\n\nSecond paragraph here.")
        #expect(analysis.kind == .text)
    }

    @Test func longSingleLineWithoutPunctuationIsText() throws {
        let input = "this is a rather long line of words without any punctuation at all"
        #expect(try #require(TextAnalyzer.analyze(input, rules: rules)).kind == .text)
    }

    @Test func customRulesApply() throws {
        let custom = LanguageRules(foreignTarget: "zh-Hant", chineseTarget: "ja")
        #expect(TextAnalyzer.analyze("apple", rules: custom)?.targetLanguage == "zh-Hant")
        #expect(TextAnalyzer.analyze("苹果", rules: custom)?.targetLanguage == "ja")
    }

    @Test func sameLanguageRuleFallsBackToChinese() throws {
        let custom = LanguageRules(foreignTarget: "en", chineseTarget: "en")
        let analysis = try #require(TextAnalyzer.analyze("Good morning, everyone. Let's get started.", rules: custom))
        #expect(analysis.targetLanguage == "zh-Hans")
    }
}
