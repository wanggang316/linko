import Foundation

/// Bridges an `async` body into a synchronous call site.
///
/// libbox (Go) invokes several platform-interface callbacks
/// (`openTun`, `getInterfaces`, `startDefaultInterfaceMonitor`) synchronously
/// on its own goroutine-backed thread, but the NetworkExtension APIs we must
/// call from them (`setTunnelNetworkSettings`) are `async`. This helper runs
/// the async work on a detached `Task` and blocks the calling thread on a
/// semaphore until it completes, re-throwing any error.
///
/// The body is *not* required to be `@Sendable`: `runBlocking` waits on the
/// semaphore before returning, so the body never runs concurrently with the
/// caller. We carry the (potentially non-Sendable) closure across the `Task`
/// boundary inside an `@unchecked Sendable` box; the semaphore's signal/wait
/// pair provides the happens-before ordering that makes this sound. This is
/// safe only because the libbox callbacks run off the main thread, so blocking
/// them does not deadlock the app's main run loop.
func runBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let result = ResultBox<T>()
    let bodyBox = SendableBox(body)
    Task.detached {
        do {
            result.value = .success(try await bodyBox.value())
        } catch {
            result.value = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    switch result.value {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    case .none:
        throw NSError(
            domain: "LinkoTunnel",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "runBlocking produced no result"]
        )
    }
}

/// Smuggles a non-Sendable async closure across the `Task` boundary. Sound
/// because the closure runs exactly once and the caller blocks on a semaphore
/// until it finishes, so there is no concurrent access.
private final class SendableBox<T>: @unchecked Sendable {
    let value: () async throws -> T
    init(_ value: @escaping () async throws -> T) {
        self.value = value
    }
}

/// Carries the async result back across the semaphore boundary. `@unchecked
/// Sendable` is sound: written exactly once inside the detached task and read
/// only after `semaphore.wait()` returns.
private final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}
