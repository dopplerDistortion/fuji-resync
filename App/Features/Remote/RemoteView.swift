import UIKit
import SwiftUI

struct RemoteView: View {
    @Environment(WiFiRemoteController.self) private var wifi
    @Environment(BLECameraController.self) private var ble
    @AppStorage("remote.autoJoin") private var autoJoin = false

    var body: some View {
        Screen(path: ["remote"], title: "remote", subtitle: "live view and shutter over the camera's wi-fi.") {
            viewfinder

            HStack(spacing: 8) {
                Button { Task { await wifi.shutter() } } label: {
                    Text(wifi.capturing ? "exposing" : "shutter").frame(maxWidth: .infinity)
                }
                .buttonStyle(.fx(.signal))
                .disabled(!wifi.isLive || wifi.capturing)
                if ble.canShutter {
                    Button("bt shutter") { Task { await ble.shutter() } }
                        .buttonStyle(.fx(.outline))
                }
            }

            Panel(title: "wi-fi", meta: wifi.isLive ? String(format: "%.0f fps", wifi.fps) : nil) {
                switch wifi.phase {
                case .idle: StatusMark(state: .idle, text: "not connected")
                case .joining: StatusMark(state: .busy, text: "joining camera network")
                case .connecting: StatusMark(state: .busy, text: wifi.log.last ?? "connecting")
                case let .live(n): StatusMark(state: .live, text: "\(n.lowercased()) · live")
                case .fault: StatusMark(state: .fault, text: "stopped")
                }
                Toggle(isOn: $autoJoin) {
                    Text("join FUJIFILM-… wi-fi for me · paid dev account").font(Typeface.body(14)).foregroundStyle(Token.foreground)
                }
                .tint(Token.foreground)
                HStack(spacing: 8) {
                    if wifi.isLive || wifi.phase == .joining {
                        Button("disconnect") { wifi.disconnect() }.buttonStyle(.fx(.secondary, compact: true))
                    } else {
                        Button("connect") { Task { await wifi.connect(joinNetwork: autoJoin) } }
                            .buttonStyle(.fx(.default, compact: true))
                    }
                }
            }

            if case let .fault(msg) = wifi.phase {
                FaultPanel(title: "wi-fi", message: msg, action: ("retry", { Task { await wifi.connect(joinNetwork: autoJoin) } }))
            }

            if !wifi.isLive {
                Panel(title: "setup") {
                    Text("1. on the camera: menu → wireless communication (or the wi-fi shortcut). it shows a FUJIFILM-… network.\n2. on the phone: settings → wi-fi → join that network, then come back and tap connect. accept the 'resync' request on the camera the first time.\n3. stay within a few metres; live view is about 640 px wide.")
                        .font(Typeface.body(14)).foregroundStyle(Token.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onDisappear { if wifi.isLive { wifi.disconnect() } }
    }

    private var viewfinder: some View {
        ZStack {
            Rectangle().fill(Token.card)
            if let f = wifi.frame {
                Image(uiImage: f).resizable().scaledToFit()
            } else {
                Text(wifi.isLive ? "waiting for frames" : "no signal")
                    .systemLabel()
            }
            ThirdsGrid().stroke(Token.foreground.opacity(0.18), lineWidth: 1)
        }
        .aspectRatio(3 / 2, contentMode: .fit)
        .overlay(Rectangle().strokeBorder(Token.border, lineWidth: 1))
        .overlay(CropMarks().stroke(Token.mark, lineWidth: 1))
        .accessibilityLabel(wifi.frame == nil ? "no live view" : "live view")
    }
}

struct ThirdsGrid: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 1 ... 2 {
            let x = r.minX + r.width * CGFloat(i) / 3
            let y = r.minY + r.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
            p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        return p
    }
}
