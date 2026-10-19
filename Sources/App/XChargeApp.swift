import SwiftUI

@main
struct XChargeApp: App {
    @StateObject private var store = Store()
    @StateObject private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(store).environmentObject(updater)
        } label: {
            Image(nsImage: MenuBarIcon.make(percent: store.status.percent, limit: store.settings.limit,
                                            charging: store.status.charging,
                                            onCharger: store.status.plugged && !store.status.charging && !store.status.adapterDisabled,
                                            alive: store.daemonAlive))
            Text("\(store.status.percent)%")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var status = Status()
    @Published var settings: Settings { didSet { if settings != oldValue { save() } } }
    @Published private(set) var daemonAlive = false
    @Published private(set) var optimizedCharging = -1  // 1 on, 0 off, -1 unavailable
    @Published var launchAtLogin = LoginItem.isEnabled { didSet { LoginItem.set(launchAtLogin) } }
    private var timers: [Timer] = []

    static let home = FileManager.default.homeDirectoryForCurrentUser
    let settingsURL = Paths.settings(home: home)
    let commandURL = Paths.command(home: home)

    init() {
        try? FileManager.default.createDirectory(at: Paths.userDir(home: Self.home), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // First run after the v1.3 move: start from what the helper is already enforcing.
        settings = readJSON(Settings.self, from: Paths.settings(home: Self.home))
            ?? readJSON(Settings.self, from: Paths.daemonSettings)
            ?? Settings()
        if !FileManager.default.fileExists(atPath: settingsURL.path) { writeJSON(settings, to: settingsURL) }
        refresh()
        refreshOptimizedCharging()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshOptimizedCharging() }
            },
        ]
    }

    func refresh() {
        guard let s = readJSON(Status.self, from: Paths.status) else {
            if daemonAlive { daemonAlive = false }
            return
        }
        let alive = Date().timeIntervalSince(s.updated) < 15
        if alive != daemonAlive { daemonAlive = alive }
        // Only publish real changes — the timestamp alone ticks every 2 s and would redraw everything.
        var same = s
        same.updated = status.updated
        if same != status { status = s }
    }

    // The PowerUI call is a synchronous XPC round trip; keep it off the main thread.
    func refreshOptimizedCharging() {
        Task.detached {
            let v = Int(obc_state())
            await MainActor.run { if v != self.optimizedCharging { self.optimizedCharging = v } }
        }
    }

    func setOptimizedCharging(_ on: Bool) {
        optimizedCharging = on ? 1 : 0
        Task.detached {
            _ = obc_set(on)
            await MainActor.run { self.refreshOptimizedCharging() }
        }
    }

    func save() { writeJSON(settings, to: settingsURL) }

    func send(_ kind: CommandKind) {
        writeJSON(Command(kind: kind), to: commandURL)
        // The daemon reacts within milliseconds; pick up its answer right away.
        for delay in [0.15, 0.5, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refresh() }
        }
    }
}

enum LoginItem {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.ismailx.xcharge.app.plist")

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func set(_ on: Bool) {
        if on {
            let plist: [String: Any] = [
                "Label": "com.ismailx.xcharge.app",
                "ProgramArguments": ["/Applications/XCharge.app/Contents/MacOS/XCharge"],
                "RunAtLoad": true,
            ]
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: url, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

// The app icon's battery, live: fill = charge, dashed orange line = limit, bolt while charging.
enum MenuBarIcon {
    static func make(percent: Int, limit: Int, charging: Bool, onCharger: Bool, alive: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 14, height: 18), flipped: false) { _ in
            let body = NSRect(x: 3, y: 1, width: 8, height: 13.5)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.4, yRadius: 2.4)
            outline.lineWidth = 1.3
            NSColor.labelColor.setStroke()
            outline.stroke()
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 5.25, y: 15.1, width: 3.5, height: 1.7), xRadius: 0.8, yRadius: 0.8).fill()

            let inner = body.insetBy(dx: 1.75, dy: 1.75)
            let h = max(1, inner.height * CGFloat(min(100, max(0, percent))) / 100)
            let fill = NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: h),
                                    xRadius: 1.2, yRadius: 1.2)
            if alive {
                NSGradient(colors: [NSColor(red: 0.16, green: 0.85, blue: 0.55, alpha: 1),
                                    NSColor(red: 0.2, green: 0.55, blue: 1, alpha: 1)])!.draw(in: fill, angle: 90)
            } else {
                NSColor.systemGray.setFill(); fill.fill()
            }

            if limit < 100 {
                let y = (inner.minY + inner.height * CGFloat(limit) / 100).rounded() + 0.5
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 0.5, y: y)); line.line(to: NSPoint(x: 13.5, y: y))
                line.lineWidth = 1.2
                line.setLineDash([2, 1.2], count: 2, phase: 0)
                NSColor(red: 1, green: 0.72, blue: 0.2, alpha: 1).setStroke()
                line.stroke()
            }

            if charging {
                let b = NSBezierPath()
                for (i, p) in [(7.8, 12.0), (4.6, 7.4), (6.6, 7.4), (6.0, 3.0), (9.4, 8.2), (7.3, 8.2)].enumerated() {
                    i == 0 ? b.move(to: NSPoint(x: p.0, y: p.1)) : b.line(to: NSPoint(x: p.0, y: p.1))
                }
                b.close()
                NSColor.white.setFill(); b.fill()
            } else if onCharger {
                // Plug: battery idle, the Mac runs from the charger (like Apple's own icon).
                NSColor.white.setFill()
                NSBezierPath(rect: NSRect(x: 5.4, y: 9.6, width: 0.9, height: 2.2)).fill()
                NSBezierPath(rect: NSRect(x: 7.7, y: 9.6, width: 0.9, height: 2.2)).fill()
                NSBezierPath(roundedRect: NSRect(x: 4.6, y: 6.6, width: 4.8, height: 3.2), xRadius: 1.2, yRadius: 1.2).fill()
                NSBezierPath(rect: NSRect(x: 6.5, y: 3.6, width: 1.0, height: 3.2)).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}

// MARK: - Panel

struct PanelView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var updater: Updater
    @State private var draftLimit = 80
    @State private var showCalHelp = false
    @State private var confirmCalibration = false

    var status: Status { store.status }
    var plugged: Bool { status.plugged }

    var body: some View {
        VStack(spacing: 12) {
            header
            limitCard
            calibrationCard
            optionsCard
            footer
        }
        .padding(14)
        .frame(width: 400)
        .onAppear {
            draftLimit = store.settings.limit
            store.refresh()
            store.refreshOptimizedCharging()
        }
    }

    // MARK: Header

    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(status.percent) / 100)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(status.percent)%").font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(store.daemonAlive ? status.message : "Helper not running")
                    .font(.headline)
                    .foregroundStyle(store.daemonAlive ? Color.primary : Color.red)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    stat("heart.fill", "\(status.healthPercent)%", "Battery health")
                    stat("arrow.triangle.2.circlepath", "\(status.cycles)", "Charge cycles")
                    stat("thermometer.medium", String(format: "%.0f°", status.temperatureC), "Battery temperature")
                    stat(plugged ? "powerplug.fill" : "bolt", String(format: "%+.1fW", status.watts), "Power in (+) / out (−)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    var ringColor: Color {
        switch status.mode {
        case .discharge: return .orange
        case .topUp: return .green
        case .calibration: return .purple
        case .normal: return status.charging ? .green : .blue
        }
    }

    func stat(_ icon: String, _ text: String, _ help: String) -> some View {
        HStack(spacing: 3) { Image(systemName: icon); Text(text).monospacedDigit() }.help(help)
    }

    // MARK: Limit

    var limitCard: some View {
        Card {
            HStack(spacing: 8) {
                Pill {
                    Text("Limit: ").bold() + Text("\(draftLimit)%").monospacedDigit()
                }
                Spacer()
                Button { store.send(.discharge) } label: {
                    Pill(active: status.mode == .discharge, tint: .orange) {
                        HStack(spacing: 6) { Text("Discharge"); Image(systemName: "minus.circle").font(.title3) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canDischarge)
                .opacity(canDischarge ? 1 : 0.4)
                .help("Run on battery while plugged in, until it drops to \(store.settings.limit)%")

                Button { store.send(.topUp) } label: {
                    Pill(active: status.mode == .topUp, tint: .green) {
                        HStack(spacing: 6) { Text("Top Up"); Image(systemName: "plus.circle").font(.title3) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canTopUp)
                .opacity(canTopUp ? 1 : 0.4)
                .help("Charge to 100% once (e.g. before a trip). Ends by itself when you unplug.")
            }

            LimitSlider(value: $draftLimit) { store.settings.limit = $0 }

            if let hint = limitHint {
                Label(hint, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var canDischarge: Bool {
        status.mode == .discharge || (plugged && status.mode != .calibration && status.percent > store.settings.limit)
    }

    var canTopUp: Bool { status.mode == .topUp || (plugged && status.mode != .calibration) }

    var limitHint: String? {
        switch status.mode {
        case .topUp: return "Top Up is on: charging to 100% this once. It turns off when you unplug or tap it again."
        case .discharge: return "Discharging: the Mac runs on battery while plugged in, until \(store.settings.limit)%."
        default: return plugged ? nil : "Charger not connected — Discharge and Top Up need it."
        }
    }

    // MARK: Calibration

    var calibrationCard: some View {
        Card {
            HStack {
                Image(systemName: "slider.vertical.3")
                Text("Calibration Mode").bold()
                Button { showCalHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showCalHelp) { calHelp }
                Spacer()
                if status.mode == .calibration {
                    Button("Stop", role: .destructive) { store.send(.cancel) }
                } else {
                    Button { confirmCalibration = true } label: { Label("Start Calibration", systemImage: "play.fill") }
                        .disabled(!store.daemonAlive || !plugged)
                }
            }
            .alert("Start calibration?", isPresented: $confirmCalibration) {
                Button("Start") { store.send(.calibrate) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("""
                Takes a few hours. Keep the charger connected the whole time — the Mac stays awake.
                1. Charge to 100%
                2. Run on battery down to 10% (charger stays plugged in)
                3. Charge back to 100%
                4. Hold at 100% for \(holdText)
                5. Settle at your \(store.settings.limit)% limit
                """)
            }

            HStack(alignment: .top, spacing: 0) {
                ForEach(CalStep.allCases, id: \.self) { step in
                    CalStepView(step: step, state: stepState(step), limit: store.settings.limit)
                    if step != .dischargeToLimit {
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
            }
            .padding(.vertical, 4)

            if status.mode == .calibration, let step = status.calStep {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(step.rawValue), total: Double(CalStep.allCases.count))
                        .tint(.purple)
                    Text("Step \(step.rawValue + 1) of \(CalStep.allCases.count) — \(status.message.replacingOccurrences(of: "Calibration: ", with: ""))")
                        .font(.caption)
                }
            } else if !plugged {
                Label("Connect the charger to start calibration.", systemImage: "powerplug")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Text("Hold at 100%:").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $store.settings.holdHours) {
                    Text("30 min").tag(0.5); Text("1 h").tag(1.0); Text("2 h").tag(2.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .labelsHidden()
                .disabled(status.mode == .calibration)
                Spacer()
                Text("Last: " + (status.lastCalibration.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var holdText: String { store.settings.holdHours < 1 ? "30 minutes" : "\(Int(store.settings.holdHours)) h" }

    enum StepState { case done, current, upcoming }

    func stepState(_ step: CalStep) -> StepState {
        guard status.mode == .calibration, let cur = status.calStep else { return .upcoming }
        return step.rawValue < cur.rawValue ? .done : step == cur ? .current : .upcoming
    }

    var calHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What is Battery Calibration?").bold()
            Text("When a Mac sits on a charge limit for weeks, its battery gauge loses track of the real capacity — the percentage drifts and the limit stops lining up with reality. Calibration runs one full cycle (100 → 10 → 100, a short hold, then back to your limit) so the gauge re-learns. Keep the charger connected; the Mac stays awake until it finishes. Once a month is plenty.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 300)
    }

    // MARK: Options

    var optionsCard: some View {
        Card {
            Toggle("Open XCharge at login", isOn: $store.launchAtLogin)
                .help("The battery helper always runs at startup; this only controls the menu bar app.")
            if store.optimizedCharging >= 0 {
                HStack {
                    Toggle("macOS Optimized Battery Charging", isOn: Binding(
                        get: { store.optimizedCharging == 1 },
                        set: { store.setOptimizedCharging($0) }))
                    if store.optimizedCharging == 1 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Conflicts with the charge limit — turn it off")
                    }
                }
            }
            Divider()
            Toggle("Charge limit on", isOn: $store.settings.enabled)
            Toggle("Stop charging while asleep", isOn: $store.settings.stopChargingOnSleep)
            Toggle("Stay awake until limit is reached", isOn: $store.settings.stayAwakeUntilLimit)
            Toggle("Auto-discharge when above limit", isOn: $store.settings.autoDischarge)
            HStack {
                Toggle("Heat protection", isOn: $store.settings.heatProtection)
                Spacer()
                Stepper("\(Int(store.settings.heatLimitC))°C", value: $store.settings.heatLimitC, in: 30...45, step: 1)
                    .disabled(!store.settings.heatProtection)
            }
            Stepper("Sailing range: \(store.settings.sailing)%", value: $store.settings.sailing, in: 1...20)
                .help("How far the charge may drift below the limit before topping up again. 1% keeps it steady.")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    // MARK: Footer

    var footer: some View {
        VStack(spacing: 8) {
            if case .available(let n) = updater.state {
                Button { updater.update() } label: {
                    Label("Update now — \(n) new change\(n == 1 ? "" : "s")", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            HStack {
                Circle().fill(store.daemonAlive ? .green : .red).frame(width: 7, height: 7)
                Text(store.daemonAlive ? "Helper connected" : "Helper offline — run install.sh")
                Spacer()
                Text(updater.version).monospacedDigit()
                Button(updateLabel) { updater.check() }
                    .buttonStyle(.borderless)
                    .disabled(updater.state == .checking || updater.state == .updating)
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    var updateLabel: String {
        switch updater.state {
        case .checking: return "Checking…"
        case .updating: return "Updating…"
        case .upToDate: return "Up to date ✓"
        case .failed(let why): return why
        default: return "Check for updates"
        }
    }
}

// Custom slider: the labels sit exactly under their values (20–100), and it stays light to drag.
struct LimitSlider: View {
    @Binding var value: Int
    var onCommit: (Int) -> Void
    private let range = 20...100
    private let thumb: CGFloat = 22
    private let marks = [20, 40, 60, 80, 100]

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width - thumb
            let span = CGFloat(range.upperBound - range.lowerBound)
            let x = { (v: Int) in thumb / 2 + CGFloat(v - range.lowerBound) / span * usable }

            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.12))
                    .frame(width: usable, height: 6)
                    .offset(x: thumb / 2, y: thumb / 2 - 3)
                Capsule().fill(Color.blue)
                    .frame(width: max(0, x(value) - thumb / 2), height: 6)
                    .offset(x: thumb / 2, y: thumb / 2 - 3)
                Capsule().fill(.white)
                    .frame(width: thumb + 8, height: thumb)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: x(value) - (thumb + 8) / 2)

                ForEach(marks, id: \.self) { m in
                    Text("\(m)%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(value == m ? Color.blue : .secondary)
                        .fixedSize()
                        .position(x: x(m), y: thumb + 14)
                        .onTapGesture { value = m; onCommit(m) }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let v = Int((CGFloat(range.lowerBound) + (g.location.x - thumb / 2) / usable * span).rounded())
                        let clamped = min(range.upperBound, max(range.lowerBound, v))
                        if clamped != value { value = clamped }
                    }
                    .onEnded { _ in onCommit(value) }
            )
        }
        .frame(height: thumb + 26)
    }
}

struct CalStepView: View {
    let step: CalStep
    let state: PanelView.StepState
    let limit: Int

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: state == .current)
                .frame(height: 24)
            Text(step == .dischargeToLimit ? "Discharge\nto \(limit)%" : step.title)
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(state == .upcoming ? .secondary : .primary)
                .fontWeight(state == .current ? .bold : .regular)
        }
        .frame(maxWidth: .infinity)
        .opacity(state == .done ? 0.5 : 1)
    }

    var icon: String {
        if state == .done { return "checkmark.circle.fill" }
        switch step {
        case .charge100a, .charge100b: return "battery.100.bolt"
        case .discharge10: return "battery.25"
        case .hold: return "pause.circle.fill"
        case .dischargeToLimit: return "battery.75"
        }
    }

    var color: Color {
        switch step {
        case .charge100a, .charge100b: return .green
        case .discharge10, .dischargeToLimit: return .orange
        case .hold: return .blue
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct Pill<Content: View>: View {
    var active = false
    var tint: Color = .accentColor
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(active ? tint.opacity(0.35) : Color.primary.opacity(0.07), in: Capsule())
            .contentShape(Capsule())
    }
}
