import XCTest

@testable import LinkoKit

/// Teardown tests for `ClashWebSocketStream`. These guard the fix that removed
/// the duplicate `continuation.onTermination` assignment: only one handler now
/// runs, and it must still cancel both the receive-loop `Task` and the socket
/// so cancelling the consumer never leaks a connection or hangs `for await`.
///
/// No live Clash API is contacted. We point the socket at a closed local port
/// (the handshake fails fast) and at a never-responding endpoint (to prove
/// consumer cancellation tears the stream down promptly).
final class ClashWebSocketStreamTests: XCTestCase {
    private func ephemeralSession() -> URLSession {
        URLSession(configuration: .ephemeral)
    }

    /// A failed handshake must finish the stream (throwing) instead of hanging,
    /// proving the single termination handler still wires the error path.
    func testStreamFinishesWhenSocketCannotConnect() async throws {
        // Port 1 is reserved and never accepts a WebSocket upgrade locally.
        let request = URLRequest(url: URL(string: "ws://127.0.0.1:1/traffic")!)
        let stream = ClashWebSocketStream.make(
            request: request,
            session: ephemeralSession(),
            as: ClashTrafficTick.self
        )

        let finished = expectation(description: "stream finishes on connection failure")
        let consumer = Task {
            do {
                for try await _ in stream { /* no frames expected */ }
            } catch {
                // Expected: the socket fails to connect and the stream throws.
            }
            finished.fulfill()
        }

        await fulfillment(of: [finished], timeout: 5)
        consumer.cancel()
    }

    /// Cancelling the consuming task must tear the stream down quickly. Before
    /// the fix the first `onTermination` (which never cancelled `pump`) was the
    /// one that mattered for ordering; with a single handler that cancels both
    /// the pump and the socket, breaking out of `for await` returns promptly.
    func testConsumerCancellationTearsDownStreamPromptly() async throws {
        // A routable but silent address: the connect attempt stalls, so without
        // a working termination handler the receive loop would never return.
        let request = URLRequest(url: URL(string: "ws://10.255.255.1:9090/traffic")!)
        let stream = ClashWebSocketStream.make(
            request: request,
            session: ephemeralSession(),
            as: ClashTrafficTick.self
        )

        let returned = expectation(description: "consumer returns after cancellation")
        let consumer = Task {
            do {
                for try await _ in stream { /* never */ }
            } catch {
                // Cancellation surfaces as a finished/thrown stream; both fine.
            }
            returned.fulfill()
        }

        // Give the loop a moment to start awaiting a frame, then cancel.
        try await Task.sleep(nanoseconds: 200_000_000)
        consumer.cancel()

        // The termination handler cancels pump + socket, so this resolves well
        // under the timeout rather than waiting for a TCP connect timeout.
        await fulfillment(of: [returned], timeout: 5)
    }
}
