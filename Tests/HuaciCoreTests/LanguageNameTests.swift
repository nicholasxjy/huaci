import Testing
@testable import HuaciCore

struct LanguageNameTests {
    @Test func namesLanguagesInChinese() {
        #expect(LanguageOption.chineseName("en") == "英语")
        #expect(LanguageOption.chineseName("zh") == "中文")
        #expect(LanguageOption.chineseName("zh-Hans") == "简体中文")
        #expect(LanguageOption.chineseName("zh-Hant") == "繁体中文")
        #expect(LanguageOption.chineseName("ja") == "日语")
        #expect(LanguageOption.chineseName("nl") == "荷兰语")
        #expect(LanguageOption.chineseName(nil) == "自动识别")
    }
}
