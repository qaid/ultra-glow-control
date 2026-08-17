// LitraGlow.swift — menubar app controlling a Logitech Litra Glow USB light over IOKit HID.
//
// The Litra family is a vendor-defined HID device (not UVC), so we talk to it directly with
// IOHIDManager + IOHIDDeviceSetReport — no vendor software, no account. The 20-byte report
// protocol is the reverse-engineered one documented by timrogers/litra and kharyam/litra-driver.
//
// ponytail: single file, one ObservableObject + one view — same shape as the sibling obsbot-control
// GUI, and this panel is even simpler (three controls), so no MVVM ceremony. Visual direction and
// the Aperture.* palette / ApertureSlider / ApertureToggleStyle are intentionally shared with that
// app so the two menu-bar panels feel like one family.

import SwiftUI
import AppKit
import IOKit
import IOKit.hid
import ServiceManagement

// MARK: - Litra Glow HID protocol (reverse-engineered; source: timrogers/litra)

private enum Litra {
    static let vendorID = 0x046d          // Logitech
    static let productID = 0xc900         // Litra Glow
    static let usagePage = 0xff43         // the one HID interface that accepts these commands
    static let feature: UInt8 = 0x04      // feature index for the Glow (Beam LX uses 0x06)

    // Glow ranges.
    static let minLumen = 20
    static let maxLumen = 250
    static let minKelvin = 2700
    static let maxKelvin = 6500

    // All commands are 20-byte output reports, report id 0x11, right-padded with 0x00.
    private static func report(_ head: [UInt8]) -> [UInt8] {
        var r = [0x11, 0xff, feature] + head
        r += [UInt8](repeating: 0x00, count: max(0, 20 - r.count))
        return r
    }

    static func power(_ on: Bool) -> [UInt8] { report([0x1c, on ? 0x01 : 0x00]) }

    static func brightness(lumen: Int) -> [UInt8] {
        let v = min(max(lumen, minLumen), maxLumen)
        return report([0x4c, UInt8((v >> 8) & 0xff), UInt8(v & 0xff)])
    }

    static func temperature(kelvin: Int) -> [UInt8] {
        // Device only accepts multiples of 100.
        let snapped = (min(max(kelvin, minKelvin), maxKelvin) / 100) * 100
        return report([0x9c, UInt8((snapped >> 8) & 0xff), UInt8(snapped & 0xff)])
    }

    // Brightness percent (0-100) mapped linearly onto the lumen range, the same convention as
    // litra's setBrightnessPercentage so the numbers match the CLI if anyone cross-checks.
    static func lumen(forPercent p: Double) -> Int {
        let clamped = min(max(p, 0), 100)
        return minLumen + Int((clamped / 100 * Double(maxLumen - minLumen)).rounded())
    }
    static func percent(forLumen l: Int) -> Double {
        Double(l - minLumen) / Double(maxLumen - minLumen) * 100
    }
}

// MARK: - HID device layer

// Owns the IOHIDManager, tracks connect/disconnect, and writes 20-byte reports. Callbacks are
// scheduled on the main run loop so the @Published mutations they trigger stay on the main thread.
final class LitraHID {
    private let manager: IOHIDManager
    private var device: IOHIDDevice?

    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var isConnected: Bool { device != nil }

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Match on VID+PID only, then pick the 0xff43 interface in `matched()`. We deliberately do
        // NOT filter on kIOHIDPrimaryUsagePageKey here: that only matches when 0xff43 is the device's
        // *primary* (first) collection, and if the Litra exposes it as a secondary collection the
        // callback would never fire and the app would silently sit on "not connected". node-hid (the
        // reference litra driver) finds 0xff43 across *all* usage pairs, so we mirror that.
        let match: [String: Any] = [
            kIOHIDVendorIDKey: Litra.vendorID,
            kIOHIDProductIDKey: Litra.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            let me = Unmanaged<LitraHID>.fromOpaque(ctx!).takeUnretainedValue()
            me.matched(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            let me = Unmanaged<LitraHID>.fromOpaque(ctx!).takeUnretainedValue()
            me.removed(dev)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private var fallback: IOHIDDevice?

    private func matched(_ dev: IOHIDDevice) {
        guard device == nil else { return }
        if advertisesVendorUsage(dev) {
            open(dev)
        } else if fallback == nil {
            // Not the 0xff43 interface. Remember it; if no 0xff43 interface shows up shortly (a
            // topology where the vendor collection isn't enumerated as its own device), open this
            // one anyway — SetReport routes by report id 0x11 regardless of which we opened.
            fallback = dev
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.device == nil, let fb = self.fallback else { return }
                self.log("no 0xff43 interface seen; opening sole matching device")
                self.open(fb)
            }
        }
    }

    // Mirrors node-hid: look for usage page 0xff43 anywhere in the device's usage pairs, plus the
    // primary usage page as a fallback.
    private func advertisesVendorUsage(_ dev: IOHIDDevice) -> Bool {
        if let primary = IOHIDDeviceGetProperty(dev, kIOHIDPrimaryUsagePageKey as CFString) as? Int,
           primary == Litra.usagePage { return true }
        if let pairs = IOHIDDeviceGetProperty(dev, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]] {
            return pairs.contains { $0[kIOHIDDeviceUsagePageKey as String] == Litra.usagePage }
        }
        return false
    }

    private func open(_ dev: IOHIDDevice) {
        guard device == nil else { return }
        guard IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            log("open failed (is Logi Options+/G HUB or the Logitech app holding the light?)")
            return
        }
        device = dev
        fallback = nil
        log("connected to Litra Glow")
        onConnect?()
    }

    private func removed(_ dev: IOHIDDevice) {
        if dev == fallback { fallback = nil }
        guard dev == device else { return }
        device = nil
        log("disconnected")
        onDisconnect?()
    }

    // hidapi's macOS set_report passes the FULL buffer (leading 0x11 kept) with reportID 0x11 for a
    // numbered report; litra works through that path, so we mirror it exactly. If a future device
    // no-ops, the fallback is reportID 0x11 with bytes[1...].
    func send(_ bytes: [UInt8]) {
        guard let device else { return }
        let res = bytes.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(bytes[0]), buf.baseAddress!, bytes.count)
        }
        if res != kIOReturnSuccess { log(String(format: "SetReport failed: 0x%08x", res)) }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write("litra: \(s)\n".data(using: .utf8)!)
    }
}

// MARK: - Model

final class LightModel: ObservableObject {
    @Published var connected = false
    @Published var isOn: Bool
    @Published var brightness: Double        // 0...100 (%)
    @Published var temperature: Double       // 2700...6500 (K), stepped to 100

    let brightnessRange: ClosedRange<Double> = 0...100
    let temperatureRange = Double(Litra.minKelvin)...Double(Litra.maxKelvin)

    // Launch at login: source of truth is SMAppService, not UserDefaults, so it stays correct
    // across reboots and reflects changes made in System Settings > Login Items.
    private static var isLoginItemEnabled: Bool { SMAppService.mainApp.status == .enabled }
    @Published var launchAtLogin: Bool = LightModel.isLoginItemEnabled

    private let hid = LitraHID()
    private let defaults = UserDefaults.standard

    init() {
        // Persisted last state; re-applied whenever the light (re)connects.
        isOn = defaults.object(forKey: "isOn") as? Bool ?? true
        brightness = defaults.object(forKey: "brightness") as? Double ?? 70
        temperature = defaults.object(forKey: "temperature") as? Double ?? 4500

        hid.onConnect = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = true
                self.applyAll() // push last-known state onto the freshly-connected light
            }
        }
        hid.onDisconnect = { [weak self] in
            DispatchQueue.main.async { self?.connected = false }
        }
        connected = hid.isConnected
    }

    func refreshLaunchAtLogin() { launchAtLogin = LightModel.isLoginItemEnabled }

    // MARK: writes

    private func applyAll() {
        // ponytail: stagger the three connect-time writes ~30ms apart — three back-to-back
        // SetReports are the same HID++ flood the sliders throttle, and the light can drop the
        // 2nd/3rd on a cold reconnect.
        hid.send(Litra.power(isOn))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.hid.send(Litra.brightness(lumen: Litra.lumen(forPercent: self.brightness)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            self.hid.send(Litra.temperature(kelvin: Int(self.temperature)))
        }
    }

    func setPower(_ on: Bool) {
        isOn = on
        defaults.set(on, forKey: "isOn")
        hid.send(Litra.power(on))
    }

    func setBrightness(_ p: Double) {
        brightness = p
        defaults.set(p, forKey: "brightness")
        brightnessThrottle.fire { [weak self] in
            self?.hid.send(Litra.brightness(lumen: Litra.lumen(forPercent: p)))
        }
    }

    func setTemperature(_ k: Double) {
        let snapped = (k / 100).rounded() * 100
        temperature = snapped
        defaults.set(snapped, forKey: "temperature")
        temperatureThrottle.fire { [weak self] in
            self?.hid.send(Litra.temperature(kelvin: Int(snapped)))
        }
    }

    func applyPreset(brightness p: Double, temperature k: Double) {
        setPower(true)
        setBrightness(p)
        setTemperature(k)
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLogin = on
        do {
            on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
        } catch {
            FileHandle.standardError.write("launchAtLogin: \(on ? "register" : "unregister") failed (\(error)); reverting\n".data(using: .utf8)!)
            launchAtLogin = LightModel.isLoginItemEnabled
        }
    }

    // MARK: throttle
    private let brightnessThrottle = Throttle()
    private let temperatureThrottle = Throttle()
}

// ponytail: HID++ drops reports flooded during a slider drag, so coalesce to ~1 write / 60ms.
// Leading edge fires immediately; a trailing send is scheduled for anything that arrives inside the
// window so the value the finger stops on always lands. `last` only ever advances to a real send
// time (never to a projected future time), so a continuous drag can't push the trailing send later
// and later — the earlier inout-struct version had exactly that lag bug. Main-thread only.
final class Throttle {
    private let interval: TimeInterval = 0.06
    private var last = Date.distantPast
    private var pending: DispatchWorkItem?
    private var latest: (() -> Void)?

    func fire(_ send: @escaping () -> Void) {
        latest = send
        let now = Date()
        let elapsed = now.timeIntervalSince(last)
        if elapsed >= interval {
            last = now
            latest = nil
            send()
        } else if pending == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.last = Date()
                let s = self.latest
                self.latest = nil
                s?()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (interval - elapsed), execute: work)
        }
        // else: a trailing send is already scheduled; `latest` now holds the newest value it'll use.
    }
}

// MARK: - Aperture palette (shared visual language with obsbot-control)

enum Aperture {
    static let bgTop = Color(hex: 0x23201b)
    static let bgBottom = Color(hex: 0x191612)
    static let text = Color(hex: 0xece3d4)
    static let value = Color(hex: 0xf4ead8)
    static let label = Color(hex: 0xb3a488)
    static let fillStart = Color(hex: 0xb9762e)
    static let fillEnd = Color(hex: 0xe6b569)
    static let accent = Color(hex: 0xd99a4e)
    static let knob = Color(hex: 0xf6ecdb)
    static let hairline = Color(hex: 0x3a3226)
    static let onDark = Color(hex: 0x1c1610)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

// MARK: - Custom toggle (pill track, cream knob; amber when on)

struct ApertureToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Capsule()
                .fill(configuration.isOn ? Aperture.accent.opacity(0.85) : Color.black.opacity(0.35))
                .frame(width: 34, height: 19)
                .overlay(
                    Circle()
                        .fill(Aperture.knob)
                        .frame(width: 15, height: 15)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                        .offset(x: configuration.isOn ? 7.5 : -7.5)
                )
                .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
    }
}

// MARK: - Custom slider (amber gradient fill, cream knob with amber ring)

struct ApertureSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let onChange: (Double) -> Void
    // Optional gradient override so the temperature track can read warm->cool.
    var trackColors: [Color]? = nil

    private let trackHeight: CGFloat = 5
    private let knobSize: CGFloat = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(Aperture.label)
                    .kerning(0.4)
                Spacer()
                Text(format(value))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(Aperture.value)
            }
            GeometryReader { geo in
                let width = geo.size.width
                let span = max(range.upperBound - range.lowerBound, 1)
                let frac = CGFloat((min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span)
                let x = frac * (width - knobSize) + knobSize / 2
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.35))
                        .frame(height: trackHeight)
                    Capsule()
                        .fill(LinearGradient(colors: trackColors ?? [Aperture.fillStart, Aperture.fillEnd],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(x, trackHeight), height: trackHeight)
                        .shadow(color: Aperture.accent.opacity(0.45), radius: 4, y: 0)
                    Circle()
                        .fill(Aperture.knob)
                        .overlay(Circle().stroke(Aperture.accent, lineWidth: 2))
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .position(x: x, y: geo.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let f = min(max((g.location.x - knobSize / 2) / (width - knobSize), 0), 1)
                    let v = range.lowerBound + Double(f) * span
                    value = v
                    onChange(v)
                })
            }
            .frame(height: knobSize)
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var model: LightModel

    // Presets: (title, brightness %, temperature K).
    private let presets: [(String, Double, Double)] = [
        ("Warm", 60, 2700),
        ("Bright", 100, 6500),
        ("Video call", 80, 4500),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.connected {
                connectedBody
            } else {
                emptyState
            }
        }
        .frame(width: 288)
        .background(LinearGradient(colors: [Aperture.bgTop, Aperture.bgBottom], startPoint: .top, endPoint: .bottom))
        .onAppear { model.refreshLaunchAtLogin() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Litra Glow")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(Aperture.text)
                HStack(spacing: 6) {
                    Circle().fill(model.isOn ? Aperture.accent : Aperture.label.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .shadow(color: Aperture.accent.opacity(model.isOn ? 0.8 : 0), radius: 3)
                    Text(model.isOn ? "On" : "Off")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(Aperture.label)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.isOn }, set: { model.setPower($0) }))
                .labelsHidden()
                .toggleStyle(ApertureToggleStyle())
                .frame(width: 34)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var connectedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Rectangle().fill(Aperture.hairline).frame(height: 1)

            VStack(spacing: 16) {
                ApertureSlider(label: "BRIGHTNESS", value: $model.brightness, range: model.brightnessRange,
                               format: { "\(Int($0.rounded())) %" }, onChange: model.setBrightness)
                ApertureSlider(label: "TEMPERATURE", value: $model.temperature, range: model.temperatureRange,
                               format: { "\(Int(($0/100).rounded())*100) K" }, onChange: model.setTemperature,
                               trackColors: [Color(hex: 0xffb44d), Color(hex: 0xfff4e0), Color(hex: 0xbcd7ff)])
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .opacity(model.isOn ? 1 : 0.55)

            Rectangle().fill(Aperture.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                Text("PRESETS")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(Aperture.label)
                    .kerning(0.4)
                HStack(spacing: 8) {
                    ForEach(presets, id: \.0) { preset in
                        Button(action: { model.applyPreset(brightness: preset.1, temperature: preset.2) }) {
                            Text(preset.0)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundColor(Aperture.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(Aperture.accent.opacity(0.08))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(Aperture.accent.opacity(0.35), lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Rectangle().fill(Aperture.hairline).frame(height: 1)

            Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                Text("Launch at login")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(Aperture.text)
            }
            .toggleStyle(ApertureToggleStyle())
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Rectangle().fill(Aperture.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button(action: { NSApp.terminate(nil) }) {
                    Text("Quit")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(Aperture.label)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "lightbulb.slash")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(Aperture.accent.opacity(0.7))
            Text("No Litra Glow connected")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(Aperture.text)
            Text("Plug in the light and reopen this panel.\nQuit other Logitech apps if it stays unseen.")
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(Aperture.label)
                .multilineTextAlignment(.center)
            Button(action: { NSApp.terminate(nil) }) {
                Text("Quit").font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Aperture.label)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

// MARK: - Menu bar icon

// A monochrome glyph echoing the app icon's radiant glow (rays + core) rather than a stock
// lightbulb. Drawn as a template image so AppKit recolors it to match a light or dark menu bar.
// ponytail: the full-color squircle app icon can't be a menu-bar glyph (those must be small,
// single-color templates), so this is the reduced line-art version of the same motif. Fewer rays
// than the app icon (8 vs 12) so it stays crisp at ~18pt. Filled core when the light is on; hollow
// ring when it's off or disconnected.
enum MenuBarIcon {
    static func image(on: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: 9, y: 9)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)

            let rayInner: CGFloat = 5.4, rayOuter: CGFloat = 8.3
            ctx.setLineWidth(1.35)
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                ctx.move(to: CGPoint(x: c.x + cos(a) * rayInner, y: c.y + sin(a) * rayInner))
                ctx.addLine(to: CGPoint(x: c.x + cos(a) * rayOuter, y: c.y + sin(a) * rayOuter))
            }
            ctx.strokePath()

            let r: CGFloat = 3.0
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            if on {
                ctx.fillEllipse(in: rect)
            } else {
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: rect)
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - App

@main
struct LitraGlowApp: App {
    @StateObject private var model = LightModel()

    init() {
        // LSUIElement in Info.plist keeps us out of the Dock; this backs it up when run bare.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image(on: model.connected && model.isOn))
        }
        .menuBarExtraStyle(.window)
    }
}
