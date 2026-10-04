import Foundation
import Testing
@testable import HuaciCore

struct ResultParserTests {
    let wordRequest = TranslationRequest(text: "run", kind: .word, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))
    let textRequest = TranslationRequest(text: "Hello there.", kind: .text, sourceLanguage: "en", targetLanguage: .named("zh-Hans"))

    @Test func parsesFencedWordEntry() throws {
        let content = """
        ```json
        {"kind":"word","headword":"run","phonetic":"/rʌn/","translation":"跑",
         "senses":[{"pos":"v.","meanings":["跑","运行"]},{"pos":"n.","meanings":["跑步"]}],
         "examples":[{"source":"I run every day.","translation":"我每天跑步。"}]}
        ```
        """
        let result = try ResultParser.parse(content, for: wordRequest)
        #expect(result.kind == .word)
        #expect(result.translation == "跑")
        #expect(result.targetLanguage == "zh-Hans")
        let word = try #require(result.word)
        #expect(word.phonetic == "/rʌn/")
        #expect(word.senses == [WordSense(pos: "v.", meanings: ["跑", "运行"]), WordSense(pos: "n.", meanings: ["跑步"])])
        #expect(word.examples.first?.translation == "我每天跑步。")
    }

    @Test func uncertainFieldsBecomeNil() throws {
        let content = #"{"kind":"word","headword":"","phonetic":"null","senses":[{"pos":"","meanings":["跑"," "]},{"meanings":[]}],"examples":[{"source":""}]}"#
        let result = try ResultParser.parse(content, for: wordRequest)
        let word = try #require(result.word)
        #expect(word.headword == "run")
        #expect(word.phonetic == nil)
        #expect(word.senses == [WordSense(pos: nil, meanings: ["跑"])])
        #expect(word.examples.isEmpty)
        #expect(result.translation == "跑")
    }

    @Test func modelMayAnswerWordRequestAsText() throws {
        let result = try ResultParser.parse(#"{"kind":"text","translation":"我很好"}"#, for: wordRequest)
        #expect(result.kind == .text)
        #expect(result.word == nil)
        #expect(result.translation == "我很好")
    }

    @Test func textTranslationKeepsLineBreaks() throws {
        let result = try ResultParser.parse(#"{"kind":"text","translation":"第一段\n\n第二段"}"#, for: textRequest)
        #expect(result.translation == "第一段\n\n第二段")
        #expect(result.sourceText == "Hello there.")
    }

    @Test func plainReplyIsUsedAsTranslation() throws {
        let result = try ResultParser.parse("  你好。 \n", for: textRequest)
        #expect(result.kind == .text)
        #expect(result.translation == "你好。")
    }

    @Test(arguments: ["", "   ", #"{"kind":"word","senses":[]}"#, "{not json}"])
    func unusableRepliesThrow(_ content: String) {
        #expect(throws: TranslationError.invalidResponse) {
            try ResultParser.parse(content, for: wordRequest)
        }
    }
}
