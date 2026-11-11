import Foundation
import Testing
@testable import HuaciCore

struct ServerSentEventsTests {
    @Test(arguments: ["\n", "\r\n", "\r"])
    func joinsDataFieldsAtBlankLine(_ newline: String) {
        let stream = [": heartbeat", "event: ignored", "id: 1", "data: first", "data:  second", "data", "", ""].joined(separator: newline)
        #expect(ServerSentEvents.payloads(from: Data(stream.utf8)) == ["first\n second\n"])
    }

    @Test func incompleteFinalFrameCannotCompleteResponse() {
        let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
        let terminal = "data: {\"type\":\"response.completed\",\"response\":{}}\n"
        #expect(throws: TranslationError.invalidResponse) {
            try ChatGPTTranslator.outputText(fromEvents: Data((delta + terminal).utf8))
        }
    }

    @Test func doneMarkerDoesNotCertifyProviderCompletion() {
        let delta = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n"
        #expect(throws: TranslationError.invalidResponse) {
            try ChatGPTTranslator.outputText(fromEvents: Data((delta + "data: [DONE]\n\n").utf8))
        }
    }
}
