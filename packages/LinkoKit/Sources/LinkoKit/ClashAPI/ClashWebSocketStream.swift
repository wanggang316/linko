import Foundation

/// Bridges a `URLSessionWebSocketTask` into an `AsyncThrowingStream` of decoded
/// values from the Clash API streaming endpoints (`/connections`, `/traffic`,
/// `/logs`).
///
/// Behaviour contract:
/// - Each text/data frame is decoded as `Element`; a frame that fails to decode
///   is **skipped**, never terminating the stream (the core occasionally emits
///   keep-alive or partial frames).
/// - The stream finishes (throwing) when the socket closes or errors.
/// - Cancelling the consuming `Task` (or breaking out of `for await`) cancels
///   the underlying WebSocket task via the stream's termination handler, so the
///   socket is always torn down — no leaked connections.
enum ClashWebSocketStream {
    static func make<Element: Decodable & Sendable>(
        request: URLRequest,
        session: URLSession,
        decoder: JSONDecoder = JSONDecoder(),
        as elementType: Element.Type = Element.self
    ) -> AsyncThrowingStream<Element, Error> {
        let task = session.webSocketTask(with: request)

        return AsyncThrowingStream<Element, Error> { continuation in
            let pump = Task {
                task.resume()
                await receiveLoop(
                    task: task,
                    decoder: decoder,
                    continuation: continuation,
                    elementType: Element.self
                )
            }

            // Tearing down on any termination (consumer cancel, finish, or
            // thrown error) cancels the receive loop so it stops awaiting the
            // next frame promptly, and cancels the socket so the connection is
            // always closed — no leaked connections.
            continuation.onTermination = { _ in
                pump.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private static func receiveLoop<Element: Decodable & Sendable>(
        task: URLSessionWebSocketTask,
        decoder: JSONDecoder,
        continuation: AsyncThrowingStream<Element, Error>.Continuation,
        elementType: Element.Type
    ) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                guard let data = Self.data(from: message) else { continue }
                if let value = try? decoder.decode(Element.self, from: data) {
                    continuation.yield(value)
                }
                // Undecodable frame: skip it, keep the stream alive.
            } catch {
                if Task.isCancelled || (error as? CancellationError) != nil {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
                return
            }
        }
        continuation.finish()
    }

    private static func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data):
            return data
        case .string(let string):
            return Data(string.utf8)
        @unknown default:
            return nil
        }
    }
}
