import Foundation
import os

/// Shared JSON decoder configured to handle Python's loose numeric types.
let coralJSONDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.nonConformingFloatDecodingStrategy = .convertFromString(
        positiveInfinity: "Infinity",
        negativeInfinity: "-Infinity",
        nan: "NaN"
    )
    return d
}()

/// Connects to `/ws/coral` and streams live session updates via diff merging.
final class CoralWebSocket {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession
    private var port: Int
    private var generation = 0
    private let logger = Logger(subsystem: "com.coral.app", category: "CoralWebSocket")

    var onFullUpdate: (([Session]) -> Void)?
    var onDiff: ((_ changed: [Session], _ removed: [String]) -> Void)?
    var onDisconnect: (() -> Void)?

    init(port: Int = 8420) {
        self.port = port
        self.urlSession = URLSession(configuration: .default)
    }

    func connect() {
        generation += 1
        let currentGen = generation

        let url = URL(string: "ws://127.0.0.1:\(port)/ws/coral")!
        let task = urlSession.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        logger.info("Connecting to \(url)")
        receiveLoop(gen: currentGen)
    }

    func disconnect() {
        generation += 1
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Receive Loop

    private func receiveLoop(gen: Int) {
        guard gen == generation else { return }
        webSocketTask?.receive { [weak self] result in
            guard let self, gen == self.generation else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveLoop(gen: gen)

            case .failure(let error):
                self.logger.warning("WebSocket error: \(error)")
                DispatchQueue.main.async {
                    self.onDisconnect?()
                }
                self.scheduleReconnect(gen: gen)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let d):
            data = d
        @unknown default:
            return
        }

        do {
            let envelope = try coralJSONDecoder.decode(WSEnvelope.self, from: data)

            DispatchQueue.main.async { [self] in
                switch envelope.type {
                case "coral_update":
                    if let sessions = envelope.sessions {
                        onFullUpdate?(sessions)
                    }
                case "coral_diff":
                    let changed = envelope.changed ?? []
                    let removed = envelope.removed ?? []
                    onDiff?(changed, removed)
                default:
                    logger.debug("Unknown WS message type: \(envelope.type)")
                }
            }
        } catch {
            logger.error("Failed to decode WS message: \(error)")
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect(gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.logger.info("Reconnecting…")
            self.connect()
        }
    }
}

// MARK: - Wire Types

private struct WSEnvelope: Decodable {
    let type: String
    var sessions: [Session]?
    var changed: [Session]?
    var removed: [String]?
}
