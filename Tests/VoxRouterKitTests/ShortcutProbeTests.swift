import Foundation
import Testing
@testable import VoxRouterKit

/// Probes for two suspected defects in the fuzzy matcher.
@Suite("Shortcut matching edge cases")
struct ShortcutProbeTests {
    /// `resolve` matches in both directions, so a *short* shortcut name is a
    /// substring of almost any sentence. Nobody's current shortcuts are short
    /// enough to trigger it, but adding one named "VPN" or "Log" would start
    /// silently eating unrelated requests.
    @Test("A short shortcut name does not match an unrelated sentence")
    func shortNamesDoNotSwallowSentences() {
        let names = ["VPN", "Log", "Make GIF"]
        #expect(Shortcuts.resolve("connect the logging pipeline to the vpn box", in: names) == nil)
        #expect(Shortcuts.resolve("log the response times", in: names) == nil)
    }

    /// Genuine abbreviations still have to work — this is the reason the
    /// containment match exists at all.
    @Test("Meaningful partial names still resolve")
    func partialNamesStillResolve() {
        let names = ["Open my watchlist", "Search Letterboxd", "Water Eject"]
        #expect(Shortcuts.resolve("watchlist", in: names) == "Open my watchlist")
        #expect(Shortcuts.resolve("water eject please", in: names) == "Water Eject")
    }

    @Test("An unrelated request matches nothing")
    func unrelatedRequestsMatchNothing() {
        let names = ["Turn off the lights", "Log a film", "Make GIF"]
        for request in [
            "refactor the parser and run the tests",
            "make the gif encoder faster",
            "why is the build failing",
        ] {
            #expect(Shortcuts.resolve(request, in: names) == nil, "\"\(request)\" matched something")
        }
    }
}
