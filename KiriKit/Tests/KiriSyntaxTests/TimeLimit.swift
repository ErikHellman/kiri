import Foundation

/// A speed test's limit: as written on a developer's Mac, three times that on
/// CI (GitHub sets `CI`), whose shared runners are slower, vary from run to
/// run and run the other suites at the same time. The limits there catch a
/// change that makes something several times slower, not a busy runner.
func timeLimit(_ limit: Duration) -> Duration {
    let environment = ProcessInfo.processInfo.environment
    return environment["CI"] == nil && environment["GITHUB_ACTIONS"] == nil ? limit : limit * 3
}
