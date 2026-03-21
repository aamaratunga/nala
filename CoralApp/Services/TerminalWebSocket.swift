import Foundation
import os

/// Bidirectional WebSocket for terminal I/O at `/ws/terminal/{name}`.
final class TerminalWebSocket {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession
    private var port: Int
    private var generation = 0
    private let logger = Logger(subsystem: "com.coral.app", category: "TerminalWebSocket")

    var onOutput: ((String, Int?, Int?) -> Void)?   // content, cursor_x, cursor_y
    var onClosed: (() -> Void)?
    var onDisconnect: (() -> Void)?

    init(port: Int = 8420) {
        self.port = port
        self.urlSession = URLSession(configuration: .default)
    }

    func connect(sessionName: String, agentType: String, sessionId: String) {
        generation += 1
        let currentGen = generation

        let encodedName = sessionName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionName
        var urlString = "ws://127.0.0.1:\(port)/ws/terminal/\(encodedName)"
        urlString += "?agent_type=\(agentType)&session_id=\(sessionId)"

        guard let url = URL(string: urlString) else {
            logger.error("Invalid terminal URL: \(urlString)")
            return
        }

        let task = urlSession.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        logger.info("Connecting terminal to \(sessionName)")
        receiveLoop(gen: currentGen)
    }

    func disconnect() {
        generation += 1
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    /// Send raw terminal input (keystrokes).
    func sendInput(_ text: String) {
        let msg: [String: Any] = ["type": "terminal_input", "data": text]
        sendJSON(msg)
    }

    /// Notify server of terminal resize.
    func sendResize(cols: Int, rows: Int) {
        let msg: [String: Any] = ["type": "terminal_resize", "cols": cols, "rows": rows]
        sendJSON(msg)
    }

    // MARK: - Internal

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { [weak self] error in
            if let error {
                self?.logger.warning("Send error: \(error)")
            }
        }
    }

    private func receiveLoop(gen: Int) {
        guard gen == generation else { return }
        webSocketTask?.receive { [weak self] result in
            guard let self, gen == self.generation else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveLoop(gen: gen)

            case .failure(let error):
                self.logger.warning("Terminal WS error: \(error)")
                DispatchQueue.main.async {
                    self.onDisconnect?()
                }
                // Don't auto-reconnect terminal — the view handles reconnection on session selection
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
            let msg = try JSONDecoder().decode(TerminalMessage.self, from: data)

            DispatchQueue.main.async { [self] in
                switch msg.type {
                case "terminal_update":
                    if let content = msg.content {
                        onOutput?(content, msg.cursorX, msg.cursorY)
                    }
                case "terminal_closed":
                    onClosed?()
                default:
                    break
                }
            }
        } catch {
            logger.error("Failed to decode terminal message: \(error)")
        }
    }
}

private struct TerminalMessage: Decodable {
    let type: String
    var content: String?
    var cursorX: Int?
    var cursorY: Int?

    enum CodingKeys: String, CodingKey {
        case type, content
        case cursorX = "cursor_x"
        case cursorY = "cursor_y"
    }
}
