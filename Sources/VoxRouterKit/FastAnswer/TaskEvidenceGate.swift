import Foundation

/// Where an utterance is allowed to go: a heavy coding engine, or a *try* at
/// the on-device fast-answer tier.
public enum RouteDecision: Equatable, Sendable {
    /// Dispatch to a coding engine. `reason` names the evidence that tripped
    /// the gate, so a misroute can be diagnosed from the log instead of being
    /// reproduced by voice.
    case engine(reason: String)
    /// No task evidence found. Not a promise that the fast tier will answer —
    /// the on-device model has its own escape hatch — merely permission to try.
    case tryFast
}

/// Looks for evidence that an utterance is a *task* before the fast-answer
/// tier is allowed anywhere near it.
///
/// The two possible misroutes are not equal, and the whole design leans on
/// that. A question sent to a coding engine costs twenty seconds; a task
/// swallowed by the small on-device model is work that silently never happens
/// — the user hears a confident non-answer and their request is gone. So this
/// gate does not try to recognise questions. It hunts for task evidence, any
/// single signal routes to the engine, and only a clean miss on every signal
/// earns `.tryFast`. Every ambiguity resolves toward the engine.
///
/// Pure string heuristics on purpose: the gate runs on every utterance before
/// any model is loaded, so it must cost nothing, need no IO, and never fail.
public enum TaskEvidenceGate {

    // MARK: - Vocabulary
    //
    // All vocabulary matching is on whole words. The codebase learned this the
    // hard way: an earlier matcher substring-matched and "minus" matched a
    // prefix of "min" — here, "committee" contains "commit" and "appendix"
    // contains "app", either of which would misfire on a substring match.

    /// Bare stems of the verbs that describe work — but only when aimed at a
    /// code noun. Alone they are innocent: "write a haiku", "open the
    /// blinds". "test" and "build" appear here in their verb sense and in
    /// `codeNouns` in their noun sense; `verbNounEvidence` keeps one
    /// occurrence from playing both roles. The last row are the everyday
    /// verbs people reach for mid-thought — "change the error message" is
    /// how the work is actually phrased; the code-noun requirement is what
    /// keeps such plain words from firing on ordinary speech.
    ///
    /// Matching runs against `codingVerbs` below, which adds the inflected
    /// forms. A stem-only list let "start fixing the bug" through: the code
    /// noun was there, no verb form matched it, and the task was lost.
    static let codingVerbStems: Set<String> = [
        "fix", "refactor", "implement", "debug", "deploy", "compile", "lint",
        "patch", "rename", "revert", "merge", "rebase", "test", "build", "run",
        "write", "add", "create", "update", "delete", "install", "open",
        "make", "change", "remove", "move", "rewrite",
    ]

    /// Past forms no spelling rule reaches from a stem. Without them, "check
    /// what i wrote in the error log" pairs no verb with its nouns and the
    /// request drops to the fast tier.
    static let irregularPastForms: Set<String> = [
        "made", "wrote", "written", "rewrote", "rewritten", "built", "ran",
    ]

    /// Every matchable coding-verb form: the stems, their generated
    /// -s/-ing/-ed inflections, the irregular pasts, and the inflections of
    /// the object-free stems. Generated rather than hand-listed because an
    /// inflection list drifts as stems are added, and the drift is invisible
    /// until a spoken "keep updating the tests" silently vanishes; generation
    /// makes every future stem carry its forms automatically.
    /// `unambiguousVerbs` itself stays exact-match: its bare forms fire with
    /// no code noun to corroborate them, and widening an uncorroborated
    /// signal ("stop pushing me") is how engine bias would creep into
    /// ordinary speech. Its inflections belong here instead, where a code
    /// noun must vouch for them — before that split, "pushing the branch
    /// now" matched no verb form at all and the task vanished into the fast
    /// tier.
    static let codingVerbs: Set<String> = {
        var forms = irregularPastForms
        for stem in codingVerbStems.union(objectFreeVerbStems) {
            forms.formUnion(inflections(of: stem))
        }
        return forms
    }()

    /// Mechanical -s/-ing/-ed inflection of one stem. Deliberately
    /// over-produces: English doubles some final consonants ("debug" →
    /// "debugging") but not others ("open" → "opening"), so both variants
    /// are emitted instead of encoding which is which. A non-word like
    /// "openning" can never match a transcript, but a missing real form is a
    /// lost task — over-production costs nothing, under-production is the
    /// exact failure this table exists to prevent.
    private static func inflections(of stem: String) -> [String] {
        var forms = [stem]
        let sibilant = ["s", "sh", "ch", "x", "z"].contains { stem.hasSuffix($0) }
        forms.append(stem + (sibilant ? "es" : "s"))
        if stem.hasSuffix("e") {
            let dropped = String(stem.dropLast())
            forms.append(dropped + "ing")
            forms.append(dropped + "ed")
        } else {
            forms.append(stem + "ing")
            forms.append(stem + "ed")
            let characters = Array(stem)
            if let last = characters.last, last.isLetter,
               !"aeiouwxy".contains(last),
               characters.count >= 2,
               "aeiou".contains(characters[characters.count - 2]) {
                forms.append(stem + String(last) + "ing")
                forms.append(stem + String(last) + "ed")
            }
        }
        return forms
    }

    /// Verb forms that describe something going wrong. "why is the build
    /// failing" is a question in form and a debugging task in substance:
    /// answering it means looking at the build on this machine, which the
    /// on-device model cannot do. So a trouble verb next to a code noun is
    /// task evidence exactly as a coding verb is. "wrong" is an adjective,
    /// not a verb, but "what's wrong with the build" is how trouble is
    /// actually spoken; without it that report — and its mid-session
    /// pronoun form, "what's wrong with it" — slipped to the fast tier.
    static let troubleVerbs: Set<String> = [
        "fail", "fails", "failed", "failing",
        "break", "breaks", "breaking", "broke", "broken",
        "crash", "crashes", "crashed", "crashing",
        "wrong",
    ]

    /// Things a coding verb can be aimed at. Mentioning one of these alone is
    /// not evidence — "what's a pull request" is a fair general question — it
    /// takes a verb pointed at it.
    static let codeNouns: Set<String> = [
        "code", "file", "files", "test", "tests", "bug", "build", "repo",
        "repository", "branch", "function", "class", "method", "parser", "app",
        "script", "pr", "package", "dependency", "error", "errors", "warning",
        "log", "logs", "terminal", "commit",
    ]

    /// Two-word code nouns, matched as adjacent word pairs.
    static let codeNounBigrams: [(String, String)] = [
        ("pull", "request"), ("stack", "trace"),
    ]

    /// Verbs that mean a coding task even with no object at all. "commit and
    /// push" names no noun, and nobody says "undo" to an assistant about
    /// anything but the work. Matched exactly, never inflected: the bare
    /// form is the imperative, and only the imperative earns a route with no
    /// corroborating noun.
    static let unambiguousVerbs: Set<String> = [
        "commit", "push", "rebase", "refactor", "deploy", "revert", "undo",
    ]

    /// The `unambiguousVerbs` stems that appear in no other verb list.
    /// Their inflections are folded into `codingVerbs`, where a code noun
    /// must corroborate them — "try committing the code" and "pushing the
    /// branch now" carry the task in forms the exact-match list above
    /// cannot see, and these three stems had no other route into the
    /// inflection generator. (The rest of `unambiguousVerbs` already sits
    /// in `codingVerbStems`.)
    static let objectFreeVerbStems: Set<String> = [
        "commit", "push", "undo",
    ]

    /// Words that genuinely mark a question: wh-words plus the ask-verbs the
    /// fast tier exists to serve. Used only for the question exemptions —
    /// the mid-coding-conversation signal and the polite-order signal — and
    /// kept deliberately narrow. Auxiliaries ("can", "could",
    /// "would", "should", "is") used to sit in this list, and polite orders —
    /// "can you fix it", "could you clean that up" — sailed through the
    /// exemption to the fast tier, losing the task. A politeness prefix is
    /// not a question; anything not provably one goes to the engine.
    static let whInterrogatives: Set<String> = [
        "what", "who", "when", "where", "why", "how",
        "tell", "explain", "translate", "define", "convert",
    ]

    /// Auxiliary openers that read both ways: "can you fix it" is an order,
    /// "can you tell me what time it is" is a question. The tiebreak is
    /// whether a wh-word follows the opener — real questions carry one
    /// ("tell", "what"), orders don't. No wh-word means order, because a
    /// question misrouted to the engine is merely slow while an order
    /// misrouted to the fast tier is lost work.
    static let auxiliaryOpeners: Set<String> = [
        "can", "could", "would", "will", "do",
    ]

    /// Utterances longer than this are briefs, not questions. Nobody dictates
    /// 25 words to ask what time it is; they do to describe what they want
    /// built.
    static let wordBudget = 24

    // MARK: - Classification

    public static func classify(_ text: String, activeCodingConversation: Bool) -> RouteDecision {
        // Two tokenisations, deliberately. `rawTokens` keeps internal
        // structure — slashes, dots, case, underscores — for the code-shape
        // checks. `words` flattens to lowercase alphanumeric runs for
        // whole-word vocabulary matching, which also splits "what's" into
        // ["what", "s"] so contractions match the interrogative list.
        let rawTokens = text.split(whereSeparator: \.isWhitespace)
            .map { trimEdgePunctuation(String($0)) }
            .filter { !$0.isEmpty }
        let words = text.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)

        // Any one signal suffices; ordering only affects which reason is
        // reported, so the most specific evidence goes first.

        if let verb = words.first(where: { unambiguousVerbs.contains($0) }) {
            return .engine(reason: "unambiguous coding verb '\(verb)'")
        }

        if let evidence = verbNounEvidence(in: words) {
            return .engine(reason: evidence)
        }

        // Backticks never survive casual speech; they arrive via typed input
        // or a transcriber quoting literal code, and both mean code.
        if text.contains("`") {
            return .engine(reason: "backticks in utterance")
        }

        if let token = rawTokens.first(where: isCodeShaped) {
            return .engine(reason: "code-shaped token '\(token)'")
        }

        if rawTokens.count > wordBudget {
            return .engine(reason: "\(rawTokens.count) words — that's a brief, not a question")
        }

        // A politeness prefix is not a question in any conversation state.
        // "can you fix it" opens like a question and lands like an order; the
        // mid-conversation branch below refuses it the exemption, but that
        // defense expires with the session window while the utterance stays
        // an order — spoken cold, it walked past the gate to a model that
        // cannot fix anything. Losing work to good manners is still losing
        // work, so the polite form gates on its own evidence.
        if let verb = politeOrderEvidence(in: words) {
            return .engine(reason: "polite order carrying work verb '\(verb)'")
        }

        // Mid coding conversation, an imperative refers to the work: "make it
        // faster" means the code, and sending it to the fast tier would lose
        // the request. A question stays a question wherever it's asked — but
        // only a genuine question earns the exemption, and no question built
        // from work vocabulary ever does: "why is it crashing" is a question
        // in form and the coding conversation in substance, and the exemption
        // once waved exactly that through to a model that cannot see the
        // crash.
        if activeCodingConversation, !words.isEmpty {
            if let verb = words.first(where: {
                codingVerbs.contains($0) || troubleVerbs.contains($0)
            }) {
                return .engine(reason: "work vocabulary '\(verb)' during a coding conversation")
            }
            if !isQuestion(words) {
                return .engine(reason: "imperative during a coding conversation")
            }
        }

        // The mid-conversation defenses above expire with the session
        // timeout; the user's referents don't. A definite determiner aimed
        // at a code noun means *their* parser, not any parser, whatever the
        // conversation state.
        if let reference = definiteReference(in: words) {
            return .engine(reason: "definite reference '\(reference)'")
        }

        return .tryFast
    }

    // MARK: - Signal 1: verb aimed at a code noun

    /// Returns a reason when a coding (or trouble) verb shares the utterance
    /// with a code noun, or nil.
    ///
    /// The verb and the noun must be *different words*. "test", "tests" and
    /// "build" sit in both lists, and letting a single occurrence play both
    /// roles would route "what is a test" — a pure vocabulary question — to
    /// the engine on the strength of one word.
    private static func verbNounEvidence(in words: [String]) -> String? {
        // Every index a code noun occupies, with the label to report. A
        // bigram claims both of its indices so a dual-role word inside one
        // can't be reused as the verb.
        var nounLabels: [Int: String] = [:]
        for index in words.indices where codeNouns.contains(words[index]) {
            nounLabels[index] = words[index]
        }
        for index in words.indices.dropLast() {
            for (first, second) in codeNounBigrams
            where words[index] == first && words[index + 1] == second {
                nounLabels[index] = "\(first) \(second)"
                nounLabels[index + 1] = "\(first) \(second)"
            }
        }
        guard !nounLabels.isEmpty else { return nil }

        for index in words.indices {
            let word = words[index]
            let isCoding = codingVerbs.contains(word)
            let isTrouble = troubleVerbs.contains(word)
            guard isCoding || isTrouble else { continue }
            guard let nounIndex = nounLabels.keys.first(where: { $0 != index }) else { continue }
            let role = isCoding ? "coding verb" : "trouble verb"
            return "\(role) '\(word)' with code noun '\(nounLabels[nounIndex]!)'"
        }
        return nil
    }

    // MARK: - Signal 3: code-shaped tokens

    /// True when a token looks like it came from a codebase rather than a
    /// sentence. Ordinary speech produces none of these shapes; when one
    /// appears, either the user read code aloud or the transcriber recognised
    /// an identifier — both mean the request is about code, whatever the
    /// surrounding words say. This is why "rename the QuickNote struct" routes
    /// to the engine even though "struct" is not in the noun list.
    static func isCodeShaped(_ token: String) -> Bool {
        // Paths. Slashes essentially never survive transcription of ordinary
        // speech ("either/or" is typed, not said), so the engine-ward bias on
        // the rare false hit is the cheap side of the trade.
        if token.contains("/") { return true }
        return hasFileExtension(token) || isCamelCase(token) || isSnakeCase(token)
    }

    /// Dot + 1–5 alphanumerics as a word suffix, e.g. "main.swift". Decimals
    /// like "3.5" also match; a spoken number routed to the engine is slow,
    /// a spoken filename routed to the fast tier is lost work, so the
    /// pattern stays deliberately loose.
    private static func hasFileExtension(_ token: String) -> Bool {
        guard let dot = token.lastIndex(of: "."), dot != token.startIndex else { return false }
        let suffix = token[token.index(after: dot)...]
        guard (1...5).contains(suffix.count) else { return false }
        return suffix.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// A lowercase letter immediately followed by an uppercase one —
    /// "QuickNote", "renderFrame". Sentence-initial capitals ("Fix") don't
    /// have that transition, so normal transcription casing passes clean.
    private static func isCamelCase(_ token: String) -> Bool {
        var previousWasLowercase = false
        for character in token {
            if character.isUppercase && previousWasLowercase { return true }
            previousWasLowercase = character.isLowercase
        }
        return false
    }

    /// An underscore flanked by alphanumerics — "user_id". Flanking is
    /// required so a stray dictated underscore doesn't count as an identifier.
    private static func isSnakeCase(_ token: String) -> Bool {
        let characters = Array(token)
        for index in characters.indices where characters[index] == "_" {
            guard index > characters.startIndex, index < characters.count - 1 else { continue }
            let before = characters[index - 1]
            let after = characters[index + 1]
            if (before.isLetter || before.isNumber), (after.isLetter || after.isNumber) {
                return true
            }
        }
        return false
    }

    // MARK: - Signal 5: the polite order

    /// Returns the work verb when an auxiliary opener addresses the assistant
    /// with an order built on work vocabulary — "can you fix it", "would you
    /// rename it" — or nil.
    ///
    /// This signal fires with no code noun to corroborate it, and an
    /// uncorroborated signal is how engine bias creeps into ordinary speech —
    /// so the shape is deliberately narrow, and all three parts must hold.
    /// The auxiliary must address "you", the party that would do the work:
    /// without that check, "do it again" outside a session — no referent, no
    /// task — would gate on nothing. A coding or trouble verb must follow the
    /// address, which is what lets "could you recommend a book" through. And
    /// no wh-word may redeem the utterance as a question — the same tiebreak
    /// `isQuestion` applies — so "can you tell me what time it is" keeps the
    /// fast path this tier exists to give.
    private static func politeOrderEvidence(in words: [String]) -> String? {
        guard words.count >= 3,
              auxiliaryOpeners.contains(words[0]),
              words[1] == "you",
              !isQuestion(words) else { return nil }
        return words.dropFirst(2).first {
            codingVerbs.contains($0) || troubleVerbs.contains($0)
        }
    }

    // MARK: - Signal 6: the mid-conversation imperative

    /// True when the utterance opens as a genuine question. A wh-opener
    /// ("what time is it") qualifies outright. An auxiliary opener qualifies
    /// only when a wh-word appears somewhere after it: "can you tell me what
    /// time it is" carries "tell" and "what"; "can you fix it" carries
    /// neither and is an order wearing a question's clothes. Everything else
    /// — bare imperatives, statements, auxiliaries with no wh-word — reads
    /// as an order, because guessing "question" wrong mid-session silently
    /// loses the task while guessing "order" wrong only costs seconds.
    private static func isQuestion(_ words: [String]) -> Bool {
        guard let opener = words.first else { return false }
        if whInterrogatives.contains(opener) { return true }
        if auxiliaryOpeners.contains(opener) {
            return words.dropFirst().contains { whInterrogatives.contains($0) }
        }
        return false
    }

    // MARK: - Signal 7: the definite referent

    /// Determiners that presuppose a referent the speaker expects the
    /// listener to already share: "the parser" is *their* parser, "a parser"
    /// is any parser. The mid-conversation defenses expire with the
    /// 30-minute session timeout, but the referents in the user's head
    /// don't — after a quiet half hour, "explain the parser" was
    /// confidently answered by a model that has never seen the parser.
    /// Indefinite phrasings ("what does a parser do") deliberately stay
    /// out: general knowledge is what the fast tier is for.
    static let definiteDeterminers: Set<String> = [
        "the", "this", "that", "my", "our",
    ]

    /// Returns the determiner-plus-noun phrase when a definite determiner
    /// sits immediately before a code noun or code bigram, or nil.
    /// Adjacency is required — "the best opening moves" scatters a
    /// determiner near verb-shaped words without referring to code, and a
    /// looser window would drag ordinary speech to the engine.
    private static func definiteReference(in words: [String]) -> String? {
        for index in words.indices.dropLast() {
            guard definiteDeterminers.contains(words[index]) else { continue }
            let next = words[index + 1]
            if codeNouns.contains(next) {
                return "\(words[index]) \(next)"
            }
            guard index + 2 < words.count else { continue }
            for (first, second) in codeNounBigrams
            where next == first && words[index + 2] == second {
                return "\(words[index]) \(first) \(second)"
            }
        }
        return nil
    }

    // MARK: - Tokenisation

    /// Sentence punctuation glued onto a token by the transcriber ("it.",
    /// "swift,") would defeat the code-shape checks; interior structure is
    /// what those checks read, so only the edges are trimmed.
    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:\"'()[]{}")

    private static func trimEdgePunctuation(_ token: String) -> String {
        token.trimmingCharacters(in: edgePunctuation)
    }
}
