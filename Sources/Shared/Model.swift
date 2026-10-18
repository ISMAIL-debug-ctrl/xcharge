import Foundation

// Shared between the menu bar app (user) and the daemon (root).
// The app owns settings.json and drops command.json; the daemon owns status.json.
enum Paths {
    static let sharedDir = URL(fileURLWithPath: "/Users/Shared/XCharge")
    static let settings = sharedDir.appendingPathComponent("settings.json")
    static let command = sharedDir.appendingPathComponent("command.json")
    static let status = sharedDir.appendingPathComponent("status.json")
    static let daemonState = URL(fileURLWithPath: "/Library/Application Support/XCharge/state.json")
}

struct Settings: Codable, Equatable {
    var enabled = true
    var limit = 80                  // stop charging at this %
    var sailing = 5                 // resume charging only once below limit - sailing
    var autoDischarge = false       // if plugged in above the limit, drain down to it
    var stopChargingOnSleep = true  // the classic "limit ignored overnight" fix
    var stayAwakeUntilLimit = true  // keep the Mac awake while it charges up to the limit
    var heatProtection = true
    var heatLimitC = 35.0
    var holdHours = 1.0             // calibration hold at 100%
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

func writeJSON<T: Encodable>(_ value: T, to url: URL, mode: Int = 0o666) {
    guard let data = try? JSONEncoder.xc.encode(value) else { return }
    try? data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}
