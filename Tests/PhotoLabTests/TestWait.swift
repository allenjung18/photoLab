import Foundation
import XCTest

/// Bounded waits for tests: no poll and no semaphore in the suite can wait
/// forever. A wait that runs out records an `XCTFail` naming what it waited
/// for and returns false, so the test goes on to fail on its own assertions
/// instead of stalling the whole `swift test` run.
enum TestWait {
    /// Long enough that a loaded machine never trips it on a wait that
    /// normally takes milliseconds; short enough that a stuck test fails
    /// well inside a 600 s run.
    static let timeout: TimeInterval = 30
}

/// Polls `condition` on the main actor every `interval` nanoseconds until
/// it holds, `orStop` holds (the thing being waited on ended without it,
/// say a run that finished first), the polling task is cancelled, or
/// `timeout` passes. Returns true only when `condition` held; a timeout
/// also records an `XCTFail` naming `what`.
@MainActor
@discardableResult
func pollUntil(_ what: @autoclosure () -> String,
               timeout: TimeInterval = TestWait.timeout,
               interval: UInt64 = 2_000_000,
               orStop: () -> Bool = { false },
               file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if condition() { return true }
        if orStop() || Task.isCancelled { return false }
        if Date() >= deadline {
            XCTFail("timed out after \(Int(timeout)) s waiting for \(what())", file: file, line: line)
            return false
        }
        try? await Task.sleep(nanoseconds: interval)
    }
}

/// `semaphore.wait()` with a deadline, for a fake's hold or a thread parked
/// until the test lets it go. Safe from any thread. On a timeout it records
/// an `XCTFail` naming `what` and returns false, and the caller carries on
/// as if released.
@discardableResult
func boundedWait(_ semaphore: DispatchSemaphore, _ what: String,
                 timeout: TimeInterval = TestWait.timeout,
                 file: StaticString = #filePath, line: UInt = #line) -> Bool {
    if semaphore.wait(timeout: .now() + timeout) == .success { return true }
    XCTFail("timed out after \(Int(timeout)) s waiting for \(what)", file: file, line: line)
    return false
}

/// Set once on the main actor when a run the test awaits has returned, so
/// a poller started beside it can stop instead of waiting for a state the
/// finished run will never show.
@MainActor
final class RunEnded {
    private(set) var value = false
    func mark() { value = true }
}
