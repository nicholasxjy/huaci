import Foundation

@MainActor
final class SelectionPollGate {
    private var entered = false
    private var start: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        start?.resume()
        start = nil
        await withCheckedContinuation { pending = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { start = $0 }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}
