import Foundation
import Testing
@testable import HuaciCore

@Suite(.serialized)
struct KeychainTests {
    /// A throwaway service so the test never touches the app's real items.
    let keychain = Keychain(service: "app.huaci.Huaci.tests.\(UUID().uuidString)")

    @Test func containsTracksWriteAndDelete() {
        defer { keychain.delete(.personalAPIKey) }
        #expect(!keychain.contains(.personalAPIKey))

        #expect(keychain.write("sk-test", for: .personalAPIKey))
        #expect(keychain.contains(.personalAPIKey))
        #expect(keychain.read(.personalAPIKey) == "sk-test")

        #expect(keychain.delete(.personalAPIKey))
        #expect(!keychain.contains(.personalAPIKey))
    }
}
