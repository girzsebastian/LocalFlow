import Foundation

/// Every filesystem location Softspoke uses, resolved in one place.
///
/// macOS keeps the `~/Library/Application Support/Softspoke` layout the app has
/// always used; a Windows build resolves the same names under `%APPDATA%`.
/// Nothing outside this type should build a path from the home directory — that
/// is what made the original code macOS-only in five separate files.
///
/// The resolution is written as a function of `(platform, environment, home)`
/// rather than as `#if` blocks around the values, so the Windows layout can be
/// tested from a Mac. Code inside `#if os(Windows)` that only ever compiles on
/// a Windows CI runner is code nobody has actually run.
enum AppPaths {
    enum Platform {
        case apple
        case windows
    }

    static var current: Platform {
        #if os(Windows)
        return .windows
        #else
        return .apple
        #endif
    }

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Resolution

    static func root(platform: Platform, environment: [String: String], home: URL) -> URL {
        switch platform {
        case .windows:
            // %APPDATA% is roaming application data. Falling back to the literal
            // path matters: a service or a stripped environment may not set it.
            let base = environment["APPDATA"].map(URL.init(fileURLWithPath:))
                ?? home.appendingPathComponent("AppData/Roaming")
            return base.appendingPathComponent("Softspoke")
        case .apple:
            return home.appendingPathComponent("Library/Application Support/Softspoke")
        }
    }

    /// The `claude` CLI. Installed per user on both platforms, under different
    /// names and in different places.
    static func claudeExecutable(platform: Platform, environment: [String: String], home: URL) -> URL {
        switch platform {
        case .windows:
            let appData = environment["APPDATA"].map(URL.init(fileURLWithPath:))
                ?? home.appendingPathComponent("AppData/Roaming")
            return appData.appendingPathComponent("npm/claude.cmd")
        case .apple:
            return home.appendingPathComponent(".local/bin/claude")
        }
    }

    // MARK: Migrating a library from before the rename

    /// Where the library lived when the project was called LocalFlow.
    ///
    /// Kept as a literal rather than derived from a constant, because it must
    /// never move again: it names a directory that already exists on disks
    /// belonging to people who installed the old build.
    static func legacyRoot(platform: Platform, environment: [String: String], home: URL) -> URL {
        switch platform {
        case .windows:
            let base = environment["APPDATA"].map(URL.init(fileURLWithPath:))
                ?? home.appendingPathComponent("AppData/Roaming")
            return base.appendingPathComponent("LocalFlow")
        case .apple:
            return home.appendingPathComponent("Library/Application Support/LocalFlow")
        }
    }

    /// Moves a pre-rename library to the current location. Returns true when
    /// something was moved.
    ///
    /// Safety properties, in the order they matter:
    ///
    /// - **Never overwrites.** If the current directory already exists, this
    ///   does nothing, even when a legacy directory is also present. Merging two
    ///   libraries is not something to attempt silently.
    /// - **Never copies.** `moveItem` on the same volume is a rename, so this is
    ///   instant whether the library holds one recording or eight hundred
    ///   megabytes of them.
    /// - **Never deletes on failure.** A throw leaves the legacy directory
    ///   exactly where it was, so a failed migration is recoverable by hand
    ///   rather than a lost library.
    /// - **Idempotent.** After a successful move the legacy path is gone, so
    ///   every later launch takes the fast no-op path.
    @discardableResult
    static func migrateLibraryFromLegacyName(
        platform: Platform = current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let current = root(platform: platform, environment: environment, home: home)
        let legacy = legacyRoot(platform: platform, environment: environment, home: home)

        guard !fileManager.fileExists(atPath: current.path),
              fileManager.fileExists(atPath: legacy.path) else { return false }

        try fileManager.createDirectory(at: current.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try fileManager.moveItem(at: legacy, to: current)
        return true
    }

    // MARK: The paths the app uses

    static var root: URL { root(platform: current, environment: environment, home: home) }
    static var claudeExecutable: URL { claudeExecutable(platform: current, environment: environment, home: home) }

    static var models: URL { root.appendingPathComponent("Models") }
    static var claudeWorkingDirectory: URL { root.appendingPathComponent("Claude") }

    /// Whisper weights, downloaded once by `scripts/download-models.sh`.
    static var largeModel: URL { models.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin") }
    static var baseModel: URL { models.appendingPathComponent("ggml-base-q5_1.bin") }
}
