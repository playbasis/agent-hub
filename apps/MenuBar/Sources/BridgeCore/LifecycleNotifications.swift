import Foundation

public enum BridgeLifecycleNotifications {
    public static let protocolVersion = 1
    public static let protocolVersionKey = "protocol_version"
    public static let requestIDKey = "request_id"
    public static let instanceIDKey = "instance_id"
    public static let ownerPIDKey = "owner_pid"
    public static let ownerExecutableKey = "owner_executable"
    public static let activateApp = Notification.Name(
        "dev.claudecodexbridge.activate-existing-instance"
    )
    public static let requestAppQuit = Notification.Name(
        "dev.claudecodexbridge.request-graceful-quit"
    )
    /// Posted by the running instance after it brought itself forward, so a
    /// second launch can exit at once instead of waiting.
    public static let activationAcknowledged = Notification.Name(
        "dev.claudecodexbridge.activation-acknowledged"
    )
}
