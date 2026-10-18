import Foundation

// Updates come from the GitHub repo cloned on this Mac (path baked into Info.plist at build time).
// Check = git fetch + count new commits. Update = run update.sh detached (it quits and relaunches us).
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable { case idle, checking, upToDate, available(Int), updating, failed(String) }

    @Published var state: State = .idle
    let repo = Bundle.main.object(forInfoDictionaryKey: "XChargeRepoPath") as? String
    let version: String = {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }()
    private var timer: Timer?

    init() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    func check() {
        guard let repo, state != .updating else { return }
        state = .checking
        Task.detached {
            let fetch = Self.git(["fetch", "--quiet"], in: repo)
            let count = Self.git(["rev-list", "--count", "HEAD..@{u}"], in: repo)
            await MainActor.run {
                if fetch.code != 0 {
                    self.state = .failed("Can't reach GitHub")
                } else if let n = Int(count.out.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
                    self.state = .available(n)
                } else {
                    self.state = .upToDate
                }
            }
        }
    }

    func update() {
        guard let repo else { return }
        state = .updating
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Detached so it survives update.sh quitting this app.
        p.arguments = ["-c", "nohup ./update.sh > /Users/Shared/XCharge/update.log 2>&1 &"]
        p.currentDirectoryURL = URL(fileURLWithPath: repo)
        p.environment = Self.env
        do { try p.run() } catch { state = .failed("Couldn't start update") }
    }

    nonisolated static let env: [String: String] = {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return e
    }()

    nonisolated static func git(_ args: [String], in dir: String) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
