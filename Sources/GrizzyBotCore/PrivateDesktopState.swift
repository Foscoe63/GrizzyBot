import Foundation

/// What the app shows about one bot's Private desktop.
public struct PrivateDesktopBotState: Equatable, Sendable {
    public var status: PodmanDesktopStatus?
    /// A sentence while something slow is running ("Starting the desktop…"), else nil.
    public var working: String?
    public var error: String?
    /// The latest screenshot, if the desktop is running.
    public var frame: Data?

    public init(status: PodmanDesktopStatus? = nil, working: String? = nil, error: String? = nil, frame: Data? = nil) {
        self.status = status
        self.working = working
        self.error = error
        self.frame = frame
    }
}
