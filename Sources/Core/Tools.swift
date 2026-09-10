import Foundation

/// Finds the external binaries Softspoke shells out to: `ffmpeg`,
/// `whisper-server`, `whisper-cli`.
///
/// These used to be hardcoded to `/opt/homebrew/bin`, which is Apple Silicon
/// Homebrew. That path does not exist on an Intel Mac — Homebrew lives in
/// `/usr/local` there — and obviously not on Windows, so one hardcode was
/// behind two separate bugs.
///
/// As with `AppPaths`, the platform is a parameter rather than an `#if` around
/// the values, so the Windows behaviour can be tested from a Mac.
enum Tools {
    typealias Platform = AppPaths.Platform

    /// Searched in order.
    ///
    /// On macOS the Homebrew prefixes come first so behaviour matches what
    /// Softspoke has always done, and because a GUI app launched by launchd
    /// inherits a minimal `PATH` — relying on the environment alone would find
    /// nothing. On Windows there is no equivalent convention, so `PATH` is all
    /// there is.
    static func directories(platform: Platform, environment: [String: String]) -> [String] {
        let path = environment["PATH"] ?? ""
        switch platform {
        case .windows:
            return path.split(separator: ";").map(String.init)
        case .apple:
            let fromEnvironment = path.split(separator: ":").map(String.init)
            return ["/opt/homebrew/bin", "/usr/local/bin"] + fromEnvironment + ["/usr/bin", "/bin"]
        }
    }

    /// Candidate filenames for a bare tool name. Windows needs the extension;
    /// npm-installed tools arrive as `.cmd` shims rather than real executables.
    static func candidateNames(for tool: String, platform: Platform) -> [String] {
        switch platform {
        case .windows: return ["\(tool).exe", "\(tool).cmd", tool]
        case .apple: return [tool]
        }
    }

    /// `PATH` handed to child processes, so a tool that shells out to another
    /// tool finds it too.
    static func childPath(platform: Platform, environment: [String: String]) -> String {
        let directories = directories(platform: platform, environment: environment)
        return directories.joined(separator: platform == .windows ? ";" : ":")
    }

    // MARK: What the app calls

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var searchDirectories: [String] {
        directories(platform: AppPaths.current, environment: environment)
    }

    static var childProcessPath: String {
        childPath(platform: AppPaths.current, environment: environment)
    }

    /// The located binary, or nil when the user has not installed it yet.
    /// Callers should name the missing `brew install` rather than failing with a
    /// bare path error.
    static func url(for tool: String) -> URL? {
        let names = candidateNames(for: tool, platform: AppPaths.current)
        for directory in searchDirectories {
            for name in names {
                let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }
}
