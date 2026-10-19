import Foundation

// Shared between the menu bar app (runs as the user) and the daemon (runs as root).
//
// Security model: root never writes anywhere a normal user can write.
// - App → daemon: settings.json / command.json in the logged-in user's own
//   ~/Library/Application Support/XCharge. The daemon only *reads* them, only for the
//   console user, refusing symlinks, non-regular files, foreign owners and oversized files.
// - Daemon → app: status.json in root-owned /Library/Application Support/XCharge (0755),
//   which the app can read but nobody else can write.
enum Paths {
    static let rootDir = URL(fileURLWithPath: "/Library/Application Support/XCharge")
    static let status = rootDir.appendingPathComponent("status.json")
    static let daemonState = rootDir.appendingPathComponent("state.json")
    static let daemonSettings = rootDir.appendingPathComponent("settings.json")
    static let legacySharedDir = "/Users/Shared/XCharge"  // v1.0–1.2, world-writable; removed on start

    static func userDir(home: URL) -> URL { home.appendingPathComponent("Library/Application Support/XCharge") }
    static func settings(home: URL) -> URL { userDir(home: home).appendingPathComponent("settings.json") }
    static func command(home: URL) -> URL { userDir(home: home).appendingPathComponent("command.json") }
}

struct Settings: Codable, Equatable {
    var enabled = true
    var limit = 80                  // stop charging at this %
    var sailing = 1                 // top up again once the charge drifts this far below the limit
    var autoDischarge = false       // if plugged in above the limit, drain down to it
    var stopChargingOnSleep = true  // the classic "limit ignored overnight" fix
    var stayAwakeUntilLimit = true  // keep the Mac awake while it charges up to the limit
    var heatProtection = true
    var heatLimitC = 35.0
    var holdHours = 1.0             // calibration hold at 100%

    /// Settings arrive from a user-writable file; never trust their ranges.
    func sanitized() -> Settings {
        var s = self
        s.limit = min(100, max(20, s.limit))
        s.sailing = min(20, max(1, s.sailing))
        s.heatLimitC = s.heatLimitC.isFinite ? min(45, max(30, s.heatLimitC)) : 35
        s.holdHours = s.holdHours.isFinite ? min(4, max(0.25, s.holdHours)) : 1
        return s
    }
}

enum Mode: String, Codable {
    case normal, discharge, topUp, calibration
}

enum CalStep: Int, Codable, CaseIterable {
    case charge100a, discharge10, charge100b, hold, dischargeToLimit

    var title: String {
        switch self {
        case .charge100a, .charge100b: return "Charge to\n100%"
        case .discharge10: return "Discharge\nto 10%"
        case .hold: return "Hold"
        case .dischargeToLimit: return "Discharge\nto limit"
        }
    }
}

enum CommandKind: String, Codable {
    case discharge, topUp, calibrate, cancel
}

struct Command: Codable {
    var kind: CommandKind
    var id = UUID()
    var created = Date()  // the daemon ignores stale commands (e.g. left over across a restart)
}

struct Status: Codable, Equatable {
    var updated = Date()
    var percent = 0
    var plugged = false
    var charging = false
    var adapterDisabled = false
    var chargeInhibited = false
    var temperatureC = 0.0
    var watts = 0.0
    var cycles = 0
    var healthPercent = 0
    var mode: Mode = .normal
    var calStep: CalStep?
    var holdUntil: Date?
    var lastCalibration: Date?
    var message = ""
}

extension JSONEncoder {
    static let xc: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let xc: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder.xc.decode(type, from: data)
}

func writeJSON<T: Encodable>(_ value: T, to url: URL, mode: Int = 0o644) {
    guard let data = try? JSONEncoder.xc.encode(value) else { return }
    try? data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}
