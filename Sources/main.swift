import Cocoa
import SwiftUI
import IOKit
import IOKit.ps
import ServiceManagement

// MARK: - Reading the live charging power

struct PowerReading {
    var externalConnected = false
    var isCharging = false
    var fullyCharged = false
    var chargeWatts = 0.0     // live power into the battery (V × A)
    var voltage = 0.0         // V
    var amperage = 0.0        // A
    var adapterWatts: Int?    // negotiated ceiling from the PD handshake (65W / 100W…)
    var adapterDrawWatts = 0.0 // total power pulled from the charger (into battery + running the Mac)
    var dischargeWatts = 0.0  // power leaving the battery when on battery (V × |A|)
    var percent: Int?
    var minutesToFull: Int?
    var minutesToEmpty: Int?
}

/// Reads `AppleSmartBattery` from the IORegistry — instant and low-cost.
func readPower() -> PowerReading {
    var r = PowerReading()
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return r }
    defer { IOObjectRelease(service) }

    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return r }

    r.externalConnected = (props["ExternalConnected"] as? Bool) ?? false
    r.isCharging        = (props["IsCharging"] as? Bool) ?? false
    r.fullyCharged      = (props["FullyCharged"] as? Bool) ?? false

    let mV = (props["Voltage"] as? Int) ?? 0
    let mA = (props["Amperage"] as? Int) ?? 0   // signed: + while charging, − while discharging
    r.voltage = Double(mV) / 1000.0
    if r.isCharging {
        let amps = abs(Double(mA)) / 1000.0
        r.amperage = amps
        r.chargeWatts = r.voltage * amps
    } else if !r.externalConnected {
        var dmA = mA
        if dmA == 0, let inst = props["InstantAmperage"] as? Int { dmA = inst }
        let amps = abs(Double(dmA)) / 1000.0
        r.amperage = amps
        r.dischargeWatts = r.voltage * amps
    }

    // Ceiling = the PD handshake result, individual to this charger + cable.
    // Prefer the negotiated contract (Volts × Amps); fall back to the rating.
    if let adapter = props["AdapterDetails"] as? [String: Any] {
        if let mv = adapter["AdapterVoltage"] as? Int, let ma = adapter["Current"] as? Int, mv > 0, ma > 0 {
            r.adapterWatts = Int((Double(mv) / 1000.0 * Double(ma) / 1000.0).rounded())
        } else if let w = adapter["Watts"] as? Int, w > 0 {
            r.adapterWatts = w
        }
    }

    // Total power actually drawn from the charger (into the battery + running the
    // Mac), from AppleSmartBattery's power telemetry. SystemPowerIn is in milliwatts.
    if let telem = props["PowerTelemetryData"] as? [String: Any],
       let mw = telem["SystemPowerIn"] as? Int, mw > 0 {
        r.adapterDrawWatts = Double(mw) / 1000.0
    }

    let cur = props["CurrentCapacity"] as? Int
    let max = (props["MaxCapacity"] as? Int) ?? 100
    if let cur = cur { r.percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur }

    if r.isCharging, let t = props["AvgTimeToFull"] as? Int, t > 0, t < 60000 { r.minutesToFull = t }
    if !r.externalConnected {
        let t = (props["AvgTimeToEmpty"] as? Int) ?? (props["TimeRemaining"] as? Int) ?? 0
        if t > 0, t < 60000 { r.minutesToEmpty = t }   // 65535 = "not yet known"
    }
    return r
}

struct BatteryHealth {
    var cycleCount: Int?
    var currentCapacity: Int?   // mAh, present full-charge capacity
    var designCapacity: Int?    // mAh
    var healthPercent: Int?
    var temperatureC: Double?
    var condition = "—"
}

func readBatteryHealth() -> BatteryHealth {
    var h = BatteryHealth()
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return h }
    defer { IOObjectRelease(service) }
    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let p = unmanaged?.takeRetainedValue() as? [String: Any] else { return h }
    h.cycleCount = p["CycleCount"] as? Int
    h.designCapacity = p["DesignCapacity"] as? Int
    h.currentCapacity = p["AppleRawMaxCapacity"] as? Int
    if let c = h.currentCapacity, let d = h.designCapacity, d > 0 {
        h.healthPercent = Int((Double(c) / Double(d) * 100).rounded())
    }
    if let temp = p["Temperature"] as? Int { h.temperatureC = Double(temp) / 100.0 }  // 0.01 °C
    let failure = (p["PermanentFailureStatus"] as? Int) ?? 0
    h.condition = failure == 0 ? "Normal" : "Service Recommended"
    return h
}

func formatMinutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }

/// Menu-bar icon: SF Symbol + short label.
func barContent(_ r: PowerReading) -> (symbol: String, title: String) {
    if !r.externalConnected { return ("bolt.slash", "") }
    if r.adapterDrawWatts > 0.5 { return ("bolt.fill", "\(Int(r.adapterDrawWatts.rounded()))W") }   // total draw
    if r.isCharging && r.chargeWatts >= 0.5 { return ("bolt.fill", "\(Int(r.chargeWatts.rounded()))W") }
    if r.fullyCharged { return ("bolt.fill", "") }
    return ("powerplug", "")
}

// MARK: - Shared model

final class ChargeModel: ObservableObject {
    @Published var reading = PowerReading()
    @Published var toastTitle = "Charging"
    @Published var arrowX: CGFloat = 150   // arrow tip x within the card, points at the icon
}

// MARK: - Aurora palette

extension Color {
    init(rgb: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xff) / 255,
                  green: Double((rgb >> 8) & 0xff) / 255,
                  blue: Double(rgb & 0xff) / 255,
                  opacity: alpha)
    }
}

enum Aurora {
    static let bgTop   = Color(rgb: 0x1a1430)
    static let bgBot   = Color(rgb: 0x0c0a18)
    static let blue    = Color(rgb: 0x3B82F6)
    static let violet  = Color(rgb: 0xA855F7)
    static let fillTop = Color(rgb: 0x60a5fa)
    static let fillBot = Color(rgb: 0xa855f7)
    static let wattA   = Color(rgb: 0xbcd6ff)
    static let wattB   = Color(rgb: 0xe9c8ff)
    static let green   = Color(rgb: 0x7CFFB0)
    static let wattsGradient = LinearGradient(colors: [wattA, wattB],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)
    static let fillGradient = LinearGradient(colors: [fillTop, fillBot],
                                             startPoint: .leading, endPoint: .trailing)
}

// MARK: - Card display state

struct CardDisplay {
    var big = "—"
    var unit = ""
    var statusText = ""
    var charging = false
    var sub = ""
    var ceiling: Int?
    var voltage = 0.0
    var amps = 0.0
    var fillLevel = 0.0     // 0–1, share of the charger's capacity actually in use
    var draw = 0.0          // total W pulled from the charger (the hero number when plugged in)
    var intoBattery = 0.0   // W flowing into the battery
    var systemWatts = 0.0   // W running the Mac + anything it powers (draw − into-battery)
    var showPowerSplit = false
}

func cardDisplay(_ r: PowerReading) -> CardDisplay {
    var d = CardDisplay()
    let pct = r.percent ?? 0
    d.voltage = r.voltage
    d.amps = r.amperage
    d.ceiling = r.adapterWatts
    d.draw = r.adapterDrawWatts
    d.intoBattery = r.chargeWatts
    d.systemWatts = max(r.adapterDrawWatts - r.chargeWatts, 0)

    // Liquid fill = how much of the charger's capacity is in use (total draw).
    if r.externalConnected {
        if let c = r.adapterWatts, c > 0 {
            if r.adapterDrawWatts > 0 {
                d.fillLevel = min(r.adapterDrawWatts / Double(c), 1)
                d.showPowerSplit = true
            } else {
                d.fillLevel = min(r.chargeWatts / Double(c), 1)
            }
        }
    } else {
        d.fillLevel = Double(pct) / 100   // on battery: fill shows the battery level
    }

    if r.externalConnected && r.adapterDrawWatts > 0.5 {
        // Hero = total power being drawn from the charger.
        d.big = "\(Int(r.adapterDrawWatts.rounded()))"; d.unit = "W"
        d.charging = r.isCharging || r.fullyCharged
        if r.isCharging {
            var s = "\(pct)%"
            if let m = r.minutesToFull { s += m > 600 ? " · charging slowly" : " · full in \(formatMinutes(m))" }
            d.statusText = "Charging"; d.sub = s
        } else if r.fullyCharged {
            d.statusText = "Charged"; d.sub = "\(pct)% · maintained"
        } else {
            d.statusText = "Plugged in"; d.sub = "\(pct)% · not charging"
        }
    } else if r.isCharging && r.chargeWatts >= 0.5 {
        // Fallback when draw telemetry is unavailable: show the charge rate.
        d.big = "\(Int(r.chargeWatts.rounded()))"; d.unit = "W"
        d.charging = true; d.statusText = "Charging"
        var s = "\(pct)%"
        if let m = r.minutesToFull { s += m > 600 ? " · charging slowly" : " · full in \(formatMinutes(m))" }
        d.sub = s
    } else if r.externalConnected {
        d.big = "\(pct)"; d.unit = "%"
        d.charging = r.fullyCharged || r.isCharging
        d.statusText = r.fullyCharged ? "Charged" : (r.isCharging ? "Charging" : "Plugged in")
        d.sub = r.fullyCharged ? "Fully charged" : "Measuring power…"
    } else {
        d.statusText = "On battery"
        if r.dischargeWatts >= 0.5 {
            d.big = "\(Int(r.dischargeWatts.rounded()))"; d.unit = "W"   // how fast you're draining
            var s = "\(pct)%"
            if let m = r.minutesToEmpty { s += " · \(formatMinutes(m)) left" }
            d.sub = s
        } else {
            d.big = "\(pct)"; d.unit = "%"
            d.sub = r.minutesToEmpty.map { "\(formatMinutes($0)) left" } ?? "Discharging…"
        }
    }
    return d
}

// MARK: - Animated background (gradient · drifting auroras · liquid fill)

struct AuroraBackground: View {
    var level: Double   // 0–1, share of the charger's ceiling in use
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(colors: [Aurora.bgTop, Aurora.bgBot],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                blob(color: Aurora.blue, anchor: .topLeading,
                     base: CGSize(width: -50, height: -70),
                     drift: drift(t, 9, 24, 18, 0), opacity: 0.55, t: t, period: 9)
                blob(color: Aurora.violet, anchor: .bottomTrailing,
                     base: CGSize(width: 60, height: 80),
                     drift: drift(t, 11, 22, 20, 0.4), opacity: 0.5, t: t, period: 11)
                LiquidFill(level: level, phase: t * 1.6)
            }
        }
    }

    private func drift(_ t: Double, _ period: Double, _ ax: Double, _ ay: Double, _ phase: Double) -> CGSize {
        let a = (t / period + phase) * 2 * .pi
        return CGSize(width: sin(a) * ax, height: cos(a) * ay)
    }

    private func blob(color: Color, anchor: Alignment, base: CGSize, drift: CGSize,
                      opacity: Double, t: Double, period: Double) -> some View {
        let scale = 1.05 + sin(t / period * 2 * .pi) * 0.14
        return Circle()
            .fill(RadialGradient(colors: [color, .clear], center: .center, startRadius: 0, endRadius: 95))
            .frame(width: 240, height: 240)
            .scaleEffect(scale)
            .blur(radius: 26)
            .opacity(opacity)
            .offset(x: base.width + drift.width, y: base.height + drift.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchor)
    }
}

struct LiquidFill: View {
    var level: Double   // 0–1, share of the charger's ceiling in use
    var phase: Double
    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height * CGFloat(min(max(level, 0), 1))
            ZStack(alignment: .top) {
                LinearGradient(colors: [Aurora.fillTop, Aurora.fillBot], startPoint: .top, endPoint: .bottom)
                Wave(phase: phase).fill(Aurora.fillBot).frame(height: 12).offset(y: -7)
            }
            .frame(width: geo.size.width, height: max(h, 0))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .opacity(0.22)
            .animation(.easeInOut(duration: 1.0), value: level)
        }
    }
}

struct Wave: Shape {
    var phase: Double
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height, steps = 48
        p.move(to: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: h / 2))
        for i in 0...steps {
            let x = w * CGFloat(i) / CGFloat(steps)
            let y = h / 2 + sin(Double(i) / Double(steps) * 4 * .pi + phase) * Double(h / 2 - 1)
            p.addLine(to: CGPoint(x: x, y: CGFloat(y)))
        }
        p.addLine(to: CGPoint(x: w, y: h))
        p.closeSubpath()
        return p
    }
}

/// Rounded card outline with an upward arrow tab at the top — drawn as a single
/// continuous path so the stroke has no seam where the arrow meets the body.
struct BubbleShape: Shape {
    var arrowX: CGFloat
    var arrowW: CGFloat = 22
    var arrowH: CGFloat = 8
    var radius: CGFloat = 18
    func path(in rect: CGRect) -> Path {
        let r = radius, aw = arrowW
        let bodyTop = rect.minY + arrowH
        let ax = min(max(arrowX, rect.minX + r + aw / 2 + 2), rect.maxX - r - aw / 2 - 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: bodyTop))
        p.addLine(to: CGPoint(x: ax - aw / 2, y: bodyTop))
        p.addLine(to: CGPoint(x: ax, y: rect.minY))            // arrow tip
        p.addLine(to: CGPoint(x: ax + aw / 2, y: bodyTop))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: bodyTop))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: bodyTop + r), control: CGPoint(x: rect.maxX, y: bodyTop))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: bodyTop + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: bodyTop), control: CGPoint(x: rect.minX, y: bodyTop))
        p.closeSubpath()
        return p
    }
}

// MARK: - Card pieces

struct BlinkDot: View {
    var color: Color
    var active: Bool
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let o = active ? 0.35 + 0.65 * abs(sin(t * .pi / 1.7)) : 1
            Circle().fill(color).frame(width: 6, height: 6)
                .opacity(o)
                .shadow(color: color.opacity(0.8), radius: active ? 4 : 0)
        }
        .frame(width: 6, height: 6)
    }
}

struct GlassPill: View {
    var label: String
    var value: String
    var body: some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 9.5)).tracking(0.4).foregroundColor(.white.opacity(0.5))
            Text(value).font(.system(size: 15, weight: .bold, design: .monospaced)).monospacedDigit()
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10).padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Aurora Glass detail card

struct AuroraCard: View {
    @ObservedObject var model: ChargeModel

    var body: some View {
        let d = cardDisplay(model.reading)
        let shape = BubbleShape(arrowX: model.arrowX)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("MacCharge").font(.system(size: 12, weight: .semibold)).tracking(0.4)
                    .foregroundColor(.white.opacity(0.6))
                Spacer(minLength: 8)
                BlinkDot(color: d.charging ? Aurora.green : .white.opacity(0.4), active: d.charging)
                Text(d.statusText).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.7))
            }
            .padding(.bottom, 14)

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(d.big)
                    .font(.system(size: 72, weight: .bold, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(Aurora.wattsGradient)
                if !d.unit.isEmpty {
                    Text(d.unit).font(.system(size: 26, weight: .bold)).foregroundColor(.white.opacity(0.85))
                }
            }
            .fixedSize()

            Text(d.sub).font(.system(size: 13)).foregroundColor(.white.opacity(0.55)).padding(.top, 3)

            HStack(spacing: 8) {
                if d.showPowerSplit {
                    GlassPill(label: "BATTERY", value: "\(Int(d.intoBattery.rounded()))W")
                    GlassPill(label: "SYSTEM", value: "\(Int(d.systemWatts.rounded()))W")
                    if let ceil = d.ceiling { GlassPill(label: "AVAIL", value: "\(ceil)W") }
                } else {
                    if let ceil = d.ceiling { GlassPill(label: "AVAIL", value: "\(ceil)W") }
                    GlassPill(label: "VOLTS", value: String(format: "%.2f", d.voltage))
                    GlassPill(label: "AMPS", value: String(format: "%.2f", d.amps))
                }
            }
            .padding(.top, 18)
        }
        .padding(.top, 26)        // 18 + 8 for the arrow tab
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .frame(width: 300, alignment: .leading)
        .background(AuroraBackground(level: d.fillLevel).clipShape(shape))
        .overlay(shape.stroke(.white.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Aurora Glass toast

struct ShimmerSweep: View {
    var body: some View {
        TimelineView(.animation) { tl in
            GeometryReader { geo in
                let cycle = 3.4
                let t = tl.date.timeIntervalSinceReferenceDate
                let p = (t.truncatingRemainder(dividingBy: cycle)) / cycle
                LinearGradient(colors: [.clear, .white.opacity(0.16), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: geo.size.width * (-0.4 + p * 1.8))
            }
        }
        .allowsHitTesting(false)
    }
}

struct AuroraToast: View {
    @ObservedObject var model: ChargeModel

    private var subtitle: String {
        let r = model.reading
        if r.fullyCharged { return "Battery maintained" }
        let w = r.adapterDrawWatts > 0 ? r.adapterDrawWatts : r.chargeWatts
        if r.externalConnected && w >= 0.5 { return "Drawing \(Int(w.rounded())) W from charger" }
        if !r.externalConnected {
            return r.dischargeWatts >= 0.5 ? "Using \(Int(r.dischargeWatts.rounded())) W" : "On battery"
        }
        return "Connected"
    }

    var body: some View {
        HStack(spacing: 11) {
            Text("⚡").font(.system(size: 20))
                .foregroundStyle(LinearGradient(colors: [Color(rgb: 0x7cc0ff), Color(rgb: 0xd29bff)],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.toastTitle).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Text(subtitle).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 250)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(Color(rgb: 0x281e3c, alpha: 0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
        .overlay(ShimmerSweep().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 10)
        .padding(20)   // margin so the shadow isn't clipped by the window
    }
}

// MARK: - Floating toast window

final class OverlayHUD {
    private let window: NSWindow
    private let model: ChargeModel
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 290, height: 100)
    let duration = 4.0

    init(model: ChargeModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        // The animated SwiftUI toast is created only while visible (see show) so its
        // TimelineView animations don't burn CPU when the toast is hidden.
    }

    func show(title: String) {
        model.toastTitle = title
        if window.contentView == nil {
            let host = NSHostingView(rootView: AuroraToast(model: model))
            host.frame = NSRect(origin: .zero, size: size)
            host.autoresizingMask = [.width, .height]
            window.contentView = host
        }
        position()
        hideWork?.cancel()
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.2; window.animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func hide() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3; window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.window.orderOut(nil)
            self?.window.contentView = nil   // stop the toast's animations while hidden
        })
    }

    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let x = screen.frame.midX - size.width / 2
        let y = screen.visibleFrame.maxY - size.height + 4
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Detail card panel (arrow-less, anchored under the menu-bar icon)

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class CardPanel {
    private let window: KeyPanel
    private let model: ChargeModel
    private var monitor: Any?

    init(model: ChargeModel) {
        self.model = model
        window = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 360),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The animated SwiftUI card is created only while open (see show).
    }

    var isVisible: Bool { window.isVisible }

    func toggle(from button: NSStatusBarButton) {
        isVisible ? hide() : show(from: button)
    }

    private func show(from button: NSStatusBarButton) {
        let host = NSHostingView(rootView: AuroraCard(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 360)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(size)

        guard let bwin = button.window else { return }
        let anchor = bwin.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bwin.screen ?? NSScreen.main ?? NSScreen.screens.first!
        var x = anchor.midX - size.width / 2
        x = min(x, screen.frame.maxX - size.width - 8)
        x = max(x, screen.frame.minX + 8)
        model.arrowX = anchor.midX - x           // arrow points at the icon
        let y = anchor.minY - size.height - 3     // small gap so the full arrow peak shows below the bar
        window.setFrameOrigin(NSPoint(x: x, y: y))

        window.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; window.animator().alphaValue = 1 }
        startMonitor()
    }

    func hide() {
        stopMonitor()
        window.orderOut(nil)
        window.contentView = nil   // stop the card's animations while closed
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = ChargeModel()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private lazy var card = CardPanel(model: model)
    private lazy var hud = OverlayHUD(model: model)

    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?

    private var firstRun = true
    private var lastExternal = false
    private var lastCharging = false
    private var lastBarSymbol = ""
    private var lastBarTitle = ""
    private var lastFlashWatts = 0
    private var lastPercent = 100
    private var lastFully = false
    private var lastDraw = 0.0

    private let pollInterval = 2.0          // while plugged in
    private let batteryPollInterval = 8.0   // on battery (lighter, but still live)
    private var timerInterval = 0.0
    private let wattChangeThreshold = 10

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: ["notificationsEnabled": true])
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            button.target = self
            button.action = #selector(statusClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        registerPowerNotification()
        update()
    }

    private func registerPowerNotification() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context = context else { return }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().update()
        }
        if let unmanaged = IOPSNotificationCreateRunLoopSource(callback, ctx) {
            let source = unmanaged.takeRetainedValue()
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private var notificationsEnabled: Bool { UserDefaults.standard.bool(forKey: "notificationsEnabled") }

    @objc func update() {
        var r = readPower()
        // Bridge the brief gap right after plugging in, before the charger's power
        // telemetry populates (it momentarily reads 0 W).
        if r.externalConnected, r.adapterDrawWatts < 0.5, lastDraw >= 0.5 { r.adapterDrawWatts = lastDraw }
        if r.externalConnected, r.adapterDrawWatts >= 0.5 { lastDraw = r.adapterDrawWatts }
        if !r.externalConnected { lastDraw = 0 }
        model.reading = r

        let bar = barContent(r)
        if bar.symbol != lastBarSymbol {
            let img = NSImage(systemSymbolName: bar.symbol, accessibilityDescription: "Charging status")
            img?.isTemplate = true
            statusItem.button?.image = img
            lastBarSymbol = bar.symbol
        }
        if bar.title != lastBarTitle {
            statusItem.button?.title = bar.title
            lastBarTitle = bar.title
        }

        // Fast poll while plugged in OR while the detail card is open (you're watching
        // for live changes); slow poll only when on battery with the card closed.
        let desired = (r.externalConnected || card.isVisible) ? pollInterval : batteryPollInterval
        if timer == nil || timerInterval != desired {
            timer?.invalidate()
            let t = Timer(timeInterval: desired, repeats: true) { [weak self] _ in self?.update() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            timerInterval = desired
        }

        let watts = Int((r.adapterDrawWatts > 0 ? r.adapterDrawWatts : r.chargeWatts).rounded())
        if firstRun {
            firstRun = false
            lastExternal = r.externalConnected
            lastCharging = r.isCharging
            lastFlashWatts = watts
            lastPercent = r.percent ?? 100
            lastFully = r.fullyCharged
            if notificationsEnabled { hud.show(title: r.externalConnected ? "MacChargePower" : "On battery") }
            return
        }

        var title: String?
        if r.externalConnected && !lastExternal { title = "Power connected"; lastFlashWatts = watts }
        if r.isCharging && !lastCharging { title = "Charging started"; lastFlashWatts = watts }
        if r.isCharging && abs(watts - lastFlashWatts) >= wattChangeThreshold {
            title = "Power shifted"; lastFlashWatts = watts
        }
        let pct = r.percent ?? lastPercent
        if r.isCharging && lastPercent < 80 && pct >= 80 { title = "Reached 80%" }
        if r.fullyCharged && !lastFully { title = "Fully charged" }
        if !r.externalConnected && lastPercent > 20 && pct <= 20 { title = "Low battery — \(pct)%" }
        lastExternal = r.externalConnected
        lastCharging = r.isCharging
        lastFully = r.fullyCharged
        lastPercent = pct

        if let title = title, notificationsEnabled { hud.show(title: title) }
    }

    // MARK: Status-item interaction

    @objc private func statusClick() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showMenu()
        } else if let button = statusItem.button {
            card.toggle(from: button)
            update()   // refresh now + switch to the faster poll while the card is open
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        addBatteryHealth(to: menu)
        menu.addItem(.separator())

        let notif = NSMenuItem(title: "Show Notifications",
                               action: #selector(toggleNotifications), keyEquivalent: "")
        notif.target = self
        notif.state = notificationsEnabled ? .on : .off
        menu.addItem(notif)

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MacChargePower",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Attach to the status item and click it, so macOS anchors the menu under
        // the bar itself. (Manual popUp(at:) mis-positions and jumps on hover.)
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil   // detach so left-click opens the detail card again
    }

    private func addBatteryHealth(to menu: NSMenu) {
        let h = readBatteryHealth()

        // Custom-view rows: disabled menu items get dimmed by AppKit no matter the
        // color, so we render our own labels to control darkness exactly.
        func row(_ text: String, font: NSFont, color: NSColor, leading: CGFloat) -> NSMenuItem {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = color
            label.translatesAutoresizingMaskIntoConstraints = false
            let v = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: font.pointSize + 12))
            v.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: leading),
                label.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -12),
                label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            let item = NSMenuItem()
            item.view = v
            return item
        }

        menu.addItem(row("Battery Health", font: .menuFont(ofSize: 0), color: .labelColor, leading: 21))
        menu.addItem(.separator())
        func info(_ text: String) {
            menu.addItem(row(text, font: .menuFont(ofSize: 11.5), color: .secondaryLabelColor, leading: 37))
        }
        info("Cycle count: \(h.cycleCount.map(String.init) ?? "—")")
        if let c = h.currentCapacity, let d = h.designCapacity { info("Capacity: \(c) of \(d) mAh") }
        info("Health: \(h.healthPercent.map { "\($0)%" } ?? "—")")
        if let t = h.temperatureC { info("Temperature: \(String(format: "%.0f", t)) °C") }
        info("Condition: \(h.condition)")
    }

    @objc private func toggleNotifications() {
        let key = "notificationsEnabled"
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("MacChargePower: login-item toggle failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Entry point

if CommandLine.arguments.contains("--print") {
    let r = readPower()
    print("external=\(r.externalConnected)  charging=\(r.isCharging)  full=\(r.fullyCharged)")
    print(String(format: "chargeWatts=%.1f  V=%.2f  A=%.2f", r.chargeWatts, r.voltage, r.amperage))
    print(String(format: "adapterDraw=%.1fW  toSystem=%.1fW", r.adapterDrawWatts, max(r.adapterDrawWatts - r.chargeWatts, 0)))
    print("ceiling=\(r.adapterWatts.map { "\($0)W" } ?? "n/a")  percent=\(r.percent.map { "\($0)%" } ?? "n/a")  toFull=\(r.minutesToFull.map { "\($0)m" } ?? "n/a")")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
