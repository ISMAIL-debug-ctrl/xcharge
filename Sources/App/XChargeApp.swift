import SwiftUI

@main
struct XChargeApp: App {
    @StateObject private var store = Store()
    @StateObject private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(store).environmentObject(updater)
        } label: {
            Image(systemName: store.menuIcon)
            Text("\(store.status.percent)%")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var status = Status()
    @Published var settings: Settings { didSet { if settings != oldValue { save() } } }
    @Published var daemonAlive = false
    @Published var optimizedCharging = Int(obc_state())  // 1 on, 0 off, -1 unavailable
    private var timer: Timer?

    init() {
        settings = readJSON(Settings.self, from: Paths.settings) ?? Settings()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        if let s = readJSON(Status.self, from: Paths.status) {
            status = s
            daemonAlive = Date().timeIntervalSince(s.updated) < 15
        } else {
            daemonAlive = false
        }
        optimizedCharging = Int(obc_state())
    }

    func setOptimizedCharging(_ on: Bool) {
        _ = obc_set(on)
        optimizedCharging = Int(obc_state())
    }

    func save() { writeJSON(settings, to: Paths.settings) }
    func send(_ kind: CommandKind) { writeJSON(Command(kind: kind), to: Paths.command) }

    var menuIcon: String {
        switch status.mode {
        case .discharge: return "minus.circle"
        case .topUp: return "bolt.circle"
        case .calibration: return "arrow.triangle.2.circlepath"
        case .normal:
            if !daemonAlive { return "exclamationmark.triangle" }
            if status.charging { return "bolt.fill" }
            if status.chargeInhibited && status.plugged { return "pause.circle" }
            let p = status.percent
            return p >= 88 ? "battery.100" : p >= 63 ? "battery.75" : p >= 38 ? "battery.50" : p >= 13 ? "battery.25" : "battery.0"
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var updater: Updater
    @State private var draftLimit: Double = 80
    @State private var showCalHelp = false

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
        .onAppear { draftLimit = Double(store.settings.limit) }
    }

    // Header: big percent + live state
    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(store.status.percent) / 100)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(store.status.percent)%").font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(store.daemonAlive ? store.status.message : "Helper not running")
                    .font(.headline)
                    .foregroundStyle(store.daemonAlive ? Color.primary : Color.red)
                HStack(spacing: 10) {
                    stat("heart.fill", "\(store.status.healthPercent)%")
                    stat("arrow.triangle.2.circlepath", "\(store.status.cycles)")
                    stat("thermometer.medium", String(format: "%.0f°", store.status.temperatureC))
                    stat("bolt", String(format: "%+.1fW", store.status.watts))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    var ringColor: Color {
        switch store.status.mode {
        case .discharge: return .orange
        case .topUp: return .green
        case .calibration: return .purple
        case .normal: return store.status.charging ? .green : .blue
        }
    }

    func stat(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) { Image(systemName: icon); Text(text).monospacedDigit() }
    }

    // Limit slider + Discharge / Top Up (AlDente-style)
    var limitCard: some View {
        Card {
            HStack(spacing: 8) {
                Pill {
                    Text("Limit: ").bold() + Text("\(Int(draftLimit))%").monospacedDigit()
                }
                Spacer()
                Button { store.send(.discharge) } label: {
                    Pill(active: store.status.mode == .discharge, tint: .orange) {
                        HStack(spacing: 6) { Text("Discharge"); Image(systemName: "minus.circle").font(.title3) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.status.mode == .calibration || store.status.percent <= store.settings.limit && store.status.mode != .discharge)

                Button { store.send(.topUp) } label: {
                    Pill(active: store.status.mode == .topUp, tint: .green) {
                        HStack(spacing: 6) { Text("Top Up"); Image(systemName: "plus.circle").font(.title3) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.status.mode == .calibration)
            }
            Slider(value: $draftLimit, in: 20...100, step: 1) { editing in
                if !editing { store.settings.limit = Int(draftLimit) }
            }
            .tint(.blue)
            HStack {
                ForEach([60, 70, 80, 90, 100], id: \.self) { v in
                    Button("\(v)%") { draftLimit = Double(v); store.settings.limit = v }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(Int(draftLimit) == v ? Color.accentColor : .secondary)
                    if v != 100 { Spacer() }
                }
            }
        }
    }

    // Calibration flow
    var calibrationCard: some View {
        Card {
            HStack {
                Image(systemName: "slider.vertical.3")
                Text("Calibration Mode").bold()
                Button { showCalHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showCalHelp) { calHelp }
                Spacer()
                if store.status.mode == .calibration {
                    Button("Stop", role: .destructive) { store.send(.cancel) }
                } else {
                    Button { store.send(.calibrate) } label: { Label("Start Calibration", systemImage: "play.fill") }
                        .disabled(!store.daemonAlive)
                }
            }
            HStack(spacing: 2) {
                ForEach(CalStep.allCases, id: \.self) { step in
                    CalStepView(step: step, state: stepState(step), limit: store.settings.limit)
                    if step != .dischargeToLimit {
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6)
            HStack {
                Text("Hold at 100%:").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $store.settings.holdHours) {
                    Text("30 min").tag(0.5); Text("1 h").tag(1.0); Text("2 h").tag(2.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .labelsHidden()
                Spacer()
                Text("Last: " + (store.status.lastCalibration.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    enum StepState { case done, current, upcoming }

    func stepState(_ step: CalStep) -> StepState {
        guard store.status.mode == .calibration, let cur = store.status.calStep else { return .upcoming }
        return step.rawValue < cur.rawValue ? .done : step == cur ? .current : .upcoming
    }

    var calHelp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What is Battery Calibration?").bold()
            Text("When a Mac sits on a charge limit for weeks, the battery gauge loses track of the real capacity — the percentage drifts and the limit stops being respected. Calibration runs a full cycle (100 → 10 → 100, hold, then back to your limit) so the gauge re-learns. Keep the charger connected; the Mac stays awake until it finishes. Once a month is plenty.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 300)
    }

    var optionsCard: some View {
        Card {
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
                Divider()
            }
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
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

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
            Text(step == .dischargeToLimit ? "Discharge\nto \(limit)%" : step.title)
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
                .foregroundStyle(state == .upcoming ? .secondary : .primary)
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
    }
}
