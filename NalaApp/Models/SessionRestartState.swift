import Foundation

@Observable
final class SessionRestartState: Identifiable {
    let id: String
    let originalSession: Session

    enum Phase { case killing, launching }
    var phase: Phase = .killing
    var isFinished = false
    var error: String?

    init(originalSession: Session) {
        self.id = originalSession.id
        self.originalSession = originalSession
    }
}
