import Foundation

/// When a finished command should leave a mark on its workspace (F3 L1): a
/// failure or a command that ran long enough to have been worth waiting for.
/// The mark is cosmetic; notifications still go through the HUD.
public enum CommandAttention {
    public static let longCommandNanos: UInt64 = 2_000_000_000

    public static func deservesAttention(exitCode: Int16, durationNanos: UInt64) -> Bool {
        exitCode != 0 || durationNanos >= longCommandNanos
    }
}
