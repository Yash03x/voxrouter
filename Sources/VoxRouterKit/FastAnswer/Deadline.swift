import Foundation

/// Races `operation` against a deadline; nil means the deadline won.
///
/// Lives in its own file rather than inside a backend: every fast-answer
/// backend races its model call against this helper, so letting it live
/// inside one of them means deleting that backend takes the others'
/// timeout down with it.
///
/// Deliberately *not* a task group: a group cannot return until every child
/// has finished, so an operation that ignores cancellation — a hung
/// model call, exactly the case the deadline exists for — would hold
/// the group open for as long as the hang lasts, and the "backstop" would
/// wait out the very failure it was meant to cut short. Instead both sides
/// run as unstructured tasks racing to yield first into a stream: the first
/// value decides the outcome immediately, the loser is cancelled and
/// abandoned, and its eventual yield lands in an already-finished stream and
/// is dropped. That drop is the point — a reply arriving after the engine
/// has already taken the question must not exist anywhere it could still be
/// spoken.
///
/// Errors thrown by `operation` propagate rather than reading as timeouts —
/// the caller logs the two cases differently, and folding them together
/// would hide guardrail refusals behind "timed out". The deadline side
/// swallows its own cancellation, so the race's loser can never inject an
/// error of its own.
func withDeadline<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T? {
    let (stream, continuation) = AsyncStream<Result<T?, any Error>>.makeStream()
    let work = Task {
        do { continuation.yield(.success(try await operation())) }
        catch { continuation.yield(.failure(error)) }
    }
    let deadline = Task {
        try? await Task.sleep(for: .seconds(seconds))
        continuation.yield(.success(nil))
    }
    defer {
        work.cancel()
        deadline.cancel()
        continuation.finish()
    }
    for await first in stream {
        return try first.get()
    }
    // Reached only when the surrounding task is cancelled, which ends the
    // iteration without a value; nil is already the caller's safe outcome.
    return nil
}
