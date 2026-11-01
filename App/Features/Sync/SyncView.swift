import SwiftUI
import CoreLocation
import FujiKit

struct SyncView: View {
    @Environment(BLECameraController.self) private var ble

    var body: some View {
        @Bindable var ble = ble
        Screen(path: ["sync"], title: "sync", subtitle: "location and time to the camera over bluetooth, whenever it asks.") {
            Panel(title: "bluetooth", meta: ble.savedCameraID == nil ? "not paired" : "paired") {
                status
            }

            if case let .fault(msg) = ble.phase {
                FaultPanel(title: "bluetooth", message: msg, action: ("scan again", { ble.scan() }))
            }

            if ble.isLinked {
                Panel(title: "geotag") {
                    Toggle(isOn: $ble.autoSync) {
                        Text("auto sync").font(Typeface.body(15)).foregroundStyle(Token.foreground)
                    }
                    .tint(Token.foreground)
                    LeaderRow(label: "last sent", value: ble.lastSync.map { $0.formatted(date: .omitted, time: .shortened) } ?? "never")
                    if let l = ble.lastSentLocation {
                        LeaderRow(label: "position", value: String(format: "%.4f, %.4f", l.coordinate.latitude, l.coordinate.longitude))
                        LeaderRow(label: "accuracy", value: "±\(Int(l.horizontalAccuracy)) m")
                    }
                    LeaderRow(label: "syncs", value: "\(ble.syncCount)")
                    if ble.location.authorization != .authorizedAlways {
                        Text("allow location 'always' so geotags keep flowing with the phone in your pocket.")
                            .font(Typeface.body(13)).foregroundStyle(Token.warn)
                    }
                    HStack(spacing: 8) {
                        Button("send now") { ble.syncNow() }.buttonStyle(.fx(.default, compact: true))
                        Button("forget camera") { ble.forget() }.buttonStyle(.fx(.ghost))
                    }
                }
                Text("on the camera, turn on network/usb setting → geotagging and location info so it shows the gps icon.")
                    .font(Typeface.body(13)).foregroundStyle(Token.mutedForeground)
            } else {
                pairing
            }

            if !ble.log.isEmpty {
                Panel(title: "log") {
                    ForEach(Array(ble.log.suffix(10).enumerated()), id: \.offset) { _, line in
                        Text(line).font(Typeface.diagram).foregroundStyle(Token.mutedForeground)
                    }
                }
            }
        }
        .onAppear { ble.location.requestPermission() }
    }

    @ViewBuilder private var status: some View {
        switch ble.phase {
        case .off: StatusMark(state: .fault, text: "bluetooth is off")
        case .unauthorized: StatusMark(state: .fault, text: "bluetooth not allowed for resync")
        case .idle: StatusMark(state: .idle, text: ble.savedCameraID == nil ? "no camera" : "waiting for camera in range")
        case .scanning: StatusMark(state: .busy, text: "scanning")
        case let .connecting(n): StatusMark(state: .busy, text: "connecting to \(n.lowercased())")
        case let .linked(n): StatusMark(state: .live, text: "\(n.lowercased()) · linked")
        case .fault: StatusMark(state: .fault, text: "stopped")
        }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Panel(title: "pair", meta: "once") {
                Text("on the camera: menu → network/usb setting → bluetooth settings → pairing registration. then scan here.")
                    .font(Typeface.body(14)).foregroundStyle(Token.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if ble.phase == .scanning {
                        Button("stop") { ble.stopScan() }.buttonStyle(.fx(.secondary, compact: true))
                    } else {
                        Button("scan") { ble.scan() }.buttonStyle(.fx(.default, compact: true))
                    }
                    if ble.savedCameraID != nil {
                        Button("reconnect") { ble.reconnect() }.buttonStyle(.fx(.outline, compact: true))
                    }
                }
            }
            if !ble.discovered.isEmpty {
                ListingHeader(path: "/bluetooth", count: ble.discovered.count)
                ForEach(ble.discovered) { d in
                    Button { ble.pair(d) } label: {
                        LeaderRow(label: d.name.lowercased(), value: kind(d.pairing) + " · \(d.rssi) dBm")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func kind(_ k: FujiBLE.PairingKind) -> String {
        switch k {
        case .legacy: return "legacy"
        case .secure: return "secure"
        }
    }
}
