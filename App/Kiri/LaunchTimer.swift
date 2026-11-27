import AppKit
import Darwin

/// `-KiriLaunchTiming YES` prints how long the first editor window took,
/// from process start, then quits. scripts/build.sh's numbers in the README
/// come from this.
enum LaunchTimer {
    private static var reported = false

    static func editorShown() {
        guard !reported, UserDefaults.standard.bool(forKey: "KiriLaunchTiming") else { return }
        reported = true
        // Wait for the frame that shows the window.
        DispatchQueue.main.async {
            CATransaction.flush()
            let ms = (Date().timeIntervalSince1970 - processStart()) * 1000
            print(String(format: "LAUNCH first editor window after %.0f ms", ms))
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    private static func processStart() -> TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let t = info.kp_proc.p_un.__p_starttime
        return TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000
    }
}
