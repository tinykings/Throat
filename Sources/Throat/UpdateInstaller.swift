import AppKit
import Security

/// Downloads a release's DMG, checks it was signed by the same certificate as this copy, and swaps it
/// into place. A small shell helper replaces the bundle after Throat quits, then relaunches it.
enum UpdateInstaller {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Calls back on the main queue with an error. On success it quits Throat instead of calling back.
    static func install(_ release: Release, completion: @escaping (Error) -> Void) {
        let fail = { (error: Error) in DispatchQueue.main.async { completion(error) } }
        guard let download = release.download else { return fail(Failure("This release has no DMG to install.")) }
        let destination = Bundle.main.bundleURL
        let folder = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            return fail(Failure("Throat can't replace itself in \(folder.path). Download the update instead."))
        }
        URLSession.shared.downloadTask(with: download) { file, response, error in
            guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                return fail(error ?? Failure("Couldn't download the update."))
            }
            do {
                let staged = try stage(dmg: file, next: destination)
                DispatchQueue.main.async {
                    do {
                        try relaunch(replacing: destination, with: staged)
                        NSApp.terminate(nil)
                    } catch {
                        try? FileManager.default.removeItem(at: staged)
                        completion(error)
                    }
                }
            } catch { fail(error) }
        }.resume()
    }

    /// Copies the app out of the DMG next to the running app (same volume, so the swap is a rename) and verifies it.
    private static func stage(dmg: URL, next destination: URL) throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ThroatUpdate-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let image = work.appendingPathComponent("Throat.dmg")
        try FileManager.default.moveItem(at: dmg, to: image)
        try run("/usr/bin/hdiutil", "attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path)
        defer { try? run("/usr/bin/hdiutil", "detach", mount.path, "-force", "-quiet") }

        let contents = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw Failure("The update doesn't contain an app.") }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".Throat-update-\(UUID().uuidString).app")
        try run("/usr/bin/ditto", app.path, staged.path)
        do { try verify(staged) } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// Accepts the update only if it satisfies this copy's designated requirement: same bundle ID and certificate.
    private static func verify(_ app: URL) throws {
        var current: SecCode?
        var currentStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &current) == errSecSuccess, let current,
              SecCodeCopyStaticCode(current, [], &currentStatic) == errSecSuccess, let currentStatic,
              SecCodeCopyDesignatedRequirement(currentStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate
        else { throw Failure("Couldn't read the update's signature.") }
        // An ad-hoc signed copy's requirement names its own hash, so no other build can ever match it.
        guard SecStaticCodeCheckValidity(candidate, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw Failure("The update isn't signed by the same certificate as this copy of Throat, so it wasn't installed. Download it instead.")
        }
    }

    /// Starts a detached helper that waits for Throat to quit, swaps in the new bundle (restoring the old one on failure), and reopens it.
    private static func relaunch(replacing destination: URL, with staged: URL) throws {
        let backup = destination.deletingLastPathComponent().appendingPathComponent(".Throat-previous-\(UUID().uuidString).app")
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            if mv "$2" "$4"; then
                if mv "$3" "$2"; then rm -rf "$4"; else mv "$4" "$2"; rm -rf "$3"; fi
            else
                rm -rf "$3"
            fi
            open "$2"
            """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), destination.path, staged.path, backup.path]
        try helper.run()
    }

    private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure("\(URL(fileURLWithPath: tool).lastPathComponent) failed while installing the update.")
        }
    }
}
