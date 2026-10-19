import Foundation
import IOKit
import IOKit.pwr_mgt
import SystemConfiguration

// XCharge daemon — runs as root via launchd and is the only thing that touches the SMC.
// Apple Silicon firmware on macOS 15+ exposes CHTE (charge inhibit) and CHIE (adapter off).

struct Battery {
    var percent = 0, plugged = false, charging = false
    var tempC = 0.0, watts = 0.0, cycles = 0, health = 0
}

func readBattery() -> Battery? {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
    func n(_ k: String) -> Int64 { (d[k] as? NSNumber)?.int64Value ?? 0 }
    var b = Battery()
    b.percent = Int(n("CurrentCapacity"))
    b.plugged = (d["ExternalConnected"] as? Bool) ?? false
    b.charging = (d["IsCharging"] as? Bool) ?? false
    b.tempC = Double(n("Temperature")) / 100
    b.watts = Double(n("Voltage")) * Double(n("Amperage")) / 1_000_000
    b.cycles = Int(n("CycleCount"))
    let design = n("DesignCapacity")
    b.health = design > 0 ? Int(n("AppleRawMaxCapacity") * 100 / design) : 0
    return b
}

enum SMC {
    static var inhibited: Bool {
        var b = [UInt8](repeating: 0, count: 4)
        return smc_read("CHTE", &b, 4, nil) == 4 && b.contains { $0 != 0 }
    }
    static var adapterOff: Bool {
        var b = [UInt8](repeating: 0, count: 1)
        return smc_read("CHIE", &b, 1, nil) == 1 && b[0] != 0
    }
    static func setInhibit(_ on: Bool) {
        guard on != inhibited else { return }
        let bytes: [UInt8] = on ? [1, 0, 0, 0] : [0, 0, 0, 0]
        if smc_write("CHTE", bytes, 4) != 0 { log("CHTE write failed") }
    }
    static func setAdapterOff(_ on: Bool) {
        guard on != adapterOff else { return }
        if smc_write("CHIE", [on ? 0x08 : 0x00], 1) != 0 { log("CHIE write failed") }
    }
}

func log(_ s: String) {
    FileHandle.standardError.write("[\(Date())] \(s)\n".data(using: .utf8)!)
}

struct DaemonState: Codable {
    var mode: Mode = .normal
    var calStep: CalStep?
    var holdUntil: Date?
    var lastCalibration: Date?
    var lastCommandID: UUID?
}

final class Daemon {
    var settings = (readJSON(Settings.self, from: Paths.daemonSettings) ?? Settings()).sanitized()
    var state = readJSON(DaemonState.self, from: Paths.daemonState) ?? DaemonState()
    var user: (uid: uid_t, home: URL)?
    var settingsPrint = ""
    var inputPrint = ""
    var message = ""
    var notice = ""
    var noticeUntil = Date.distantPast
    var assertion: IOPMAssertionID = 0
    var assertionType = ""

    /// Picks up the console user's settings; keeps the last good copy (root-owned) when nobody is logged in.
    func loadSettings() {
        guard let user else { return }
        let url = Paths.settings(home: user.home)
        let print = "\(user.uid)|" + fingerprint(url)
        guard print != settingsPrint else { return }
        settingsPrint = print
        guard let s = readUserJSON(Settings.self, at: url, owner: user.uid)?.sanitized(), s != settings else { return }
        settings = s
        writeJSON(settings, to: Paths.daemonSettings)
    }

    func saveState() { writeJSON(state, to: Paths.daemonState) }

    /// Called often; only does real work when the user's files changed.
    func checkInputs() {
        user = consoleUser()
        guard let user else { return }
        let print = "\(user.uid)|" + fingerprint(Paths.settings(home: user.home)) + "|" + fingerprint(Paths.command(home: user.home))
        if print != inputPrint {
            inputPrint = print
            tick()
        }
    }

    func handleCommand(_ b: Battery) {
        guard let user,
              let cmd = readUserJSON(Command.self, at: Paths.command(home: user.home), owner: user.uid),
              cmd.id != state.lastCommandID,
              abs(cmd.created.timeIntervalSinceNow) < 60 else { return }
        state.lastCommandID = cmd.id  // never deleted (root doesn't touch user files); de-duplicated by id
        saveState()
        let plugged = b.plugged || SMC.adapterOff
        func tell(_ s: String) { notice = s; noticeUntil = Date().addingTimeInterval(6) }
        switch cmd.kind {
        case .discharge:
            if state.mode == .discharge { state.mode = .normal; break }
            guard plugged else { tell("Unplugged — the battery is already discharging"); return }
            guard b.percent > settings.limit else { tell("Already at or below \(settings.limit)%"); return }
            state.mode = .discharge
        case .topUp:
            if state.mode == .topUp { state.mode = .normal; break }
            guard plugged else { tell("Plug in the charger to top up"); return }
            state.mode = .topUp
        case .calibrate:
            guard plugged else { tell("Plug in the charger to calibrate"); return }
            state.mode = .calibration
            state.calStep = .charge100a
            state.holdUntil = nil
        case .cancel:
            state.mode = .normal
            state.calStep = nil
            state.holdUntil = nil
        }
        saveState()
    }

    /// Returns (inhibit charging, disconnect adapter).
    func decide(_ b: Battery) -> (Bool, Bool) {
        let limit = settings.limit
        let plugged = b.plugged || SMC.adapterOff
        let hot = settings.heatProtection && b.tempC >= settings.heatLimitC

        switch state.mode {
        case .topUp:
            if b.plugged {
                message = b.percent >= 100 ? "Topped up — holding at 100%" : "Topping up to 100%"
                return (false, false)
            }
            state.mode = .normal  // Top Up ends when the charger is removed
            saveState()

        case .discharge:
            if b.percent > limit {
                message = "Discharging to \(limit)%"
                return (true, true)
            }
            state.mode = .normal
            saveState()

        case .calibration:
            return calibrate(b, plugged: plugged)

        case .normal:
            break
        }

        guard settings.enabled else {
            message = "Limit off"
            return (false, false)
        }

        var inhibit: Bool
        if limit >= 100 {
            inhibit = false
        } else if b.percent >= limit {
            inhibit = true
        } else if b.percent <= limit - settings.sailing {
            inhibit = false
        } else {
            inhibit = SMC.inhibited  // sailing range: keep doing what we were doing
        }
        // The gauge often reads 1–2% high after the Mac rests; don't flip to battery for that — stay on the plug.
        let drain = settings.autoDischarge && plugged && b.percent > limit + 2
        if hot && !inhibit {
            inhibit = true
            message = String(format: "Too hot (%.0f°C) — paused", b.tempC)
        } else if drain {
            message = "Above limit — discharging to \(limit)%"
        } else if !plugged {
            message = "On battery"
        } else if inhibit {
            message = "Holding \(b.percent)% — running on the charger"
        } else {
            message = "Charging to \(limit)%"
        }
        return (inhibit || drain, drain)
    }

    func calibrate(_ b: Battery, plugged: Bool) -> (Bool, Bool) {
        let step = state.calStep ?? .charge100a
        func advance(_ next: CalStep?) {
            state.calStep = next
            if next == .hold { state.holdUntil = Date().addingTimeInterval(settings.holdHours * 3600) }
            if next == nil {
                state.mode = .normal
                state.holdUntil = nil
                state.lastCalibration = Date()
            }
            saveState()
        }
        switch step {
        case .charge100a, .charge100b:
            if b.percent >= 100 && !b.charging {
                advance(step == .charge100a ? .discharge10 : .hold)
                return calibrate(b, plugged: plugged)
            }
            message = plugged ? "Calibration: charging to 100%" : "Calibration: plug in the charger"
            return (false, false)
        case .discharge10:
            if b.percent <= 10 {
                advance(.charge100b)
                return calibrate(b, plugged: plugged)
            }
            message = "Calibration: discharging to 10% (\(b.percent)%)"
            return (true, true)
        case .hold:
            let until = state.holdUntil ?? Date()
            if Date() >= until {
                advance(.dischargeToLimit)
                return calibrate(b, plugged: plugged)
            }
            let mins = Int(until.timeIntervalSinceNow / 60) + 1
            message = "Calibration: holding at 100% (\(mins) min left)"
            return (false, false)
        case .dischargeToLimit:
            if b.percent <= settings.limit {
                advance(nil)
                message = "Calibration done"
                return (true, false)
            }
            message = "Calibration: discharging to \(settings.limit)%"
            return (true, true)
        }
    }

    func setAssertion(_ type: String?) {
        guard type ?? "" != assertionType else { return }
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        assertionType = type ?? ""
        if let type {
            IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "XCharge is managing the battery" as CFString, &assertion)
        }
    }

    func tick() {
        user = consoleUser()
        loadSettings()
        guard let b = readBattery() else { return }
        handleCommand(b)
        let (inhibit, adapterOff) = decide(b)
        SMC.setInhibit(inhibit)
        SMC.setAdapterOff(adapterOff)

        // Stay awake while draining (adapter off counts as battery power) or charging toward the limit.
        if adapterOff || state.mode == .calibration {
            setAssertion(kIOPMAssertPreventUserIdleSystemSleep)
        } else if settings.enabled && settings.stayAwakeUntilLimit && b.plugged && !inhibit && state.mode == .normal {
            setAssertion(kIOPMAssertionTypePreventSystemSleep)
        } else {
            setAssertion(nil)
        }

        var s = Status()
        s.percent = b.percent
        s.plugged = b.plugged || adapterOff
        s.charging = b.charging
        s.adapterDisabled = SMC.adapterOff
        s.chargeInhibited = SMC.inhibited
        s.temperatureC = b.tempC
        s.watts = b.watts
        s.cycles = b.cycles
        s.healthPercent = b.health
        s.mode = state.mode
        s.calStep = state.mode == .calibration ? (state.calStep ?? .charge100a) : nil
        s.holdUntil = state.holdUntil
        s.lastCalibration = state.lastCalibration
        s.message = Date() < noticeUntil ? notice : message
        writeJSON(s, to: Paths.status)
    }

    func willSleep() {
        // Never drain while asleep; optionally freeze charging so the limit survives the night.
        SMC.setAdapterOff(false)
        let charging100 = state.mode == .topUp || (state.mode == .calibration && state.calStep != .discharge10)
        if settings.enabled && settings.stopChargingOnSleep && !charging100 {
            SMC.setInhibit(true)
        }
    }

    func restore() {
        SMC.setAdapterOff(false)
        SMC.setInhibit(false)
        setAssertion(nil)
    }
}

// MARK: - Boot

setvbuf(stdout, nil, _IOLBF, 0)
guard getuid() == 0 else { log("must run as root"); exit(1) }
guard smc_open() == 0 else { log("cannot open AppleSMC"); exit(1) }

umask(0o022)
prepareRootDir()
removeLegacySharedDir()
let daemon = Daemon()

// Sleep / wake notifications (kIOMessageCanSystemSleep / SystemWillSleep / SystemHasPoweredOn)
var rootPort: io_connect_t = 0
var notifier: io_object_t = 0
let powerCallback: IOServiceInterestCallback = { _, _, messageType, arg in
    switch messageType {
    case 0xE000_0270:
        IOAllowPowerChange(rootPort, Int(bitPattern: arg))
    case 0xE000_0280:
        daemon.willSleep()
        IOAllowPowerChange(rootPort, Int(bitPattern: arg))
    case 0xE000_0300:
        daemon.tick()
    default: break
    }
}
var notifyPort: IONotificationPortRef?
rootPort = IORegisterForSystemPower(nil, &notifyPort, powerCallback, &notifier)
if let notifyPort {
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
}

// Restore normal charging when launchd stops us.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { daemon.restore(); exit(0) }
    src.resume()
    signalSources.append(src)
}

log("XCharge daemon started")
daemon.tick()
// Full tick every 2 s; a cheap stat() of the user's two files every 0.25 s for instant button response.
let timer = Timer(timeInterval: 2, repeats: true) { _ in daemon.tick() }
let inputTimer = Timer(timeInterval: 0.25, repeats: true) { _ in daemon.checkInputs() }
RunLoop.main.add(timer, forMode: .default)
RunLoop.main.add(inputTimer, forMode: .default)
RunLoop.main.run()
