import Foundation
import os

/// os_log-backed logging. Chosen over print/file IO because it is effectively
/// free when the subsystem isn't being streamed — this runs in an always-on
/// daemon where logging must never show up in a latency profile.
public enum Log {
    public static let quota = Logger(subsystem: subsystem, category: "quota")
    public static let routing = Logger(subsystem: subsystem, category: "routing")
    public static let dispatch = Logger(subsystem: subsystem, category: "dispatch")
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let speech = Logger(subsystem: subsystem, category: "speech")

    private static let subsystem = "dev.voxrouter"
}

/// Signposts for measuring the latency budget end to end. Stream with:
///   xcrun xctrace record --template 'Time Profile' --launch -- .build/release/voxrouter
public enum Trace {
    public static let signposter = OSSignposter(subsystem: "dev.voxrouter", category: .pointsOfInterest)
}
