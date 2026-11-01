import XCTest
@testable import FujiKit

/// In-memory stream: replies are queued in advance, sends are recorded.
final class MockStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound = Data()
    private(set) var sent: [Data] = []
    /// Called on every send so tests can enqueue a reply that depends on the request.
    var responder: ((Data, MockStream) -> Void)?

    func enqueue(_ d: Data) { lock.lock(); inbound.append(d); lock.unlock() }

    func send(_ data: Data) async throws {
        lock.lock(); sent.append(data); let r = responder; lock.unlock()
        r?(data, self)
    }

    func receive(exactly count: Int) async throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard inbound.count >= count else { throw PTPError.disconnected }
        let out = inbound.prefix(count)
        inbound.removeFirst(count)
        return Data(out)
    }
}

/// A fake camera that answers Get/SetDevicePropValue from a dictionary, per selected slot.
final class FakeCamera: @unchecked Sendable {
    var slot: UInt16 = 1
    var slots: [UInt16: [UInt16: Data]] = [:]
    var names: [UInt16: String] = [:]
    var rejects: Set<UInt16> = []

    func attach(to stream: MockStream) {
        var pendingSet: (code: UInt16, tid: UInt32)?
        stream.responder = { [unowned self] data, s in
            var buf = data
            while let (c, used) = try! PTPContainer.decode(prefixOf: buf) {
                buf.removeFirst(used)
                switch (c.type, c.code) {
                case (.command, PTPOperation.getDevicePropValue.rawValue):
                    let code = UInt16(c.params[0])
                    let value: Data?
                    if code == FujiProp.presetSlot { var w = ByteWriter(); w.u16(slot); value = w.data }
                    else if code == FujiProp.presetName { var w = ByteWriter(); w.ptpString(names[slot] ?? ""); value = w.data }
                    else { value = slots[slot]?[code] }
                    if let value {
                        s.enqueue(PTPContainer(type: .data, code: c.code, transactionID: c.transactionID, payload: value).encoded())
                        s.enqueue(PTPContainer(type: .response, code: 0x2001, transactionID: c.transactionID).encoded())
                    } else {
                        s.enqueue(PTPContainer(type: .response, code: 0x200A, transactionID: c.transactionID).encoded())
                    }
                case (.command, PTPOperation.setDevicePropValue.rawValue):
                    pendingSet = (UInt16(c.params[0]), c.transactionID)
                case (.data, _):
                    guard let p = pendingSet else { continue }
                    pendingSet = nil
                    var code: UInt16 = 0x2001
                    if rejects.contains(p.code) { code = 0x201C }
                    else if p.code == FujiProp.presetSlot { var r = ByteReader(c.payload); slot = try! r.u16() }
                    else if p.code == FujiProp.presetName { var r = ByteReader(c.payload); names[slot] = try! r.ptpString() }
                    else { slots[slot, default: [:]][p.code] = c.payload }
                    s.enqueue(PTPContainer(type: .response, code: code, transactionID: p.tid).encoded())
                default:
                    s.enqueue(PTPContainer(type: .response, code: 0x2001, transactionID: c.transactionID).encoded())
                }
            }
        }
    }
}

final class ContainerTests: XCTestCase {
    func testCommandRoundTrip() throws {
        let c = PTPContainer.command(0x1015, transactionID: 7, params: [0xD18C])
        let bytes = c.encoded()
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(Array(bytes.prefix(12)), [16, 0, 0, 0, 1, 0, 0x15, 0x10, 7, 0, 0, 0])
        let (d, used) = try XCTUnwrap(PTPContainer.decode(prefixOf: bytes + Data([0xFF])))
        XCTAssertEqual(used, 16)
        XCTAssertEqual(d, c)
        XCTAssertEqual(d.params, [0xD18C])
    }

    func testPartialContainerNeedsMoreBytes() throws {
        let bytes = PTPContainer.command(0x1002, transactionID: 1, params: [1]).encoded()
        XCTAssertNil(try PTPContainer.decode(prefixOf: bytes.prefix(10)))
    }

    func testPTPStringRoundTrip() throws {
        var w = ByteWriter(); w.ptpString("Kodachrome 64")
        XCTAssertEqual(w.data.first, 14) // 13 chars + NUL
        var r = ByteReader(w.data)
        XCTAssertEqual(try r.ptpString(), "Kodachrome 64")
        var e = ByteWriter(); e.ptpString("")
        XCTAssertEqual(e.data, Data([0]))
    }

    func testStreamTransportCollectsDataPhase() async throws {
        let s = MockStream()
        s.enqueue(PTPContainer(type: .data, code: 0x1015, transactionID: 1, payload: Data([0x05, 0x00])).encoded())
        s.enqueue(PTPContainer(type: .response, code: 0x2001, transactionID: 1).encoded())
        let t = StreamPTPTransport(stream: s)
        let r = try await t.execute(PTPCommand(.getDevicePropValue, [0xDF01]), dataOut: nil)
        XCTAssertEqual(r.code, .ok)
        XCTAssertEqual(r.data, Data([0x05, 0x00]))
    }

    func testStreamTransportSendsDataOut() async throws {
        let s = MockStream()
        s.enqueue(PTPContainer(type: .response, code: 0x2001, transactionID: 1).encoded())
        let t = StreamPTPTransport(stream: s)
        _ = try await t.execute(PTPCommand(.setDevicePropValue, [0xD18C]), dataOut: Data([3, 0]))
        let sent = try XCTUnwrap(s.sent.first)
        let (cmd, used) = try XCTUnwrap(PTPContainer.decode(prefixOf: sent))
        XCTAssertEqual(cmd.type, .command)
        let (data, _) = try XCTUnwrap(PTPContainer.decode(prefixOf: sent.dropFirst(used)))
        XCTAssertEqual(data.type, .data)
        XCTAssertEqual(data.payload, Data([3, 0]))
        XCTAssertEqual(data.transactionID, cmd.transactionID)
    }
}

final class PresetCodecTests: XCTestCase {
    func kodachrome() -> Recipe {
        Recipe(name: "Kodachrome 64", filmSimulation: .classicChrome, grain: .weakSmall,
               colorChrome: .strong, colorChromeBlue: .weak, whiteBalance: .daylight,
               wbShiftRed: 2, wbShiftBlue: -5, dynamicRange: .dr200, highlight: 0, shadow: 0.5,
               color: 2, sharpness: 1, noiseReduction: -4, clarity: 3)
    }

    func dict(_ writes: [PropWrite]) -> [UInt16: Data] {
        Dictionary(uniqueKeysWithValues: writes.map { ($0.code, $0.value) })
    }

    func u16(_ d: Data?) -> UInt16? { guard let d else { return nil }; var r = ByteReader(d); return try? r.u16() }

    func testEncodingMatchesCameraConventions() {
        let w = dict(PresetCodec.encode(kodachrome()))
        XCTAssertEqual(u16(w[FujiProp.filmSimulation]), 0x0B)
        XCTAssertEqual(u16(w[FujiProp.dynamicRange]), 200)
        XCTAssertEqual(u16(w[FujiProp.grainEffect]), 2)
        XCTAssertEqual(u16(w[FujiProp.colorChrome]), 3)
        XCTAssertEqual(u16(w[FujiProp.colorChromeBlue]), 2)
        XCTAssertNil(w[FujiProp.smoothSkin], "X-T30 II rejects smooth skin writes")
        XCTAssertEqual(u16(w[FujiProp.whiteBalance]), 0x0004)
        XCTAssertNil(w[FujiProp.wbColorTemp], "Kelvin is only written for color-temperature WB")
        XCTAssertEqual(u16(w[FujiProp.wbShiftBlue]).map { Int16(bitPattern: $0) }, -5)
        XCTAssertEqual(u16(w[FujiProp.shadowTone]), 5)
        XCTAssertEqual(u16(w[FujiProp.color]), 20)
        XCTAssertEqual(u16(w[FujiProp.noiseReduction]), 0x8000)
        XCTAssertEqual(u16(w[FujiProp.clarity]), 30)
        XCTAssertNil(w[FujiProp.monoWarmCool])
    }

    func testKelvinWrittenRightAfterWhiteBalance() {
        var r = kodachrome(); r.whiteBalance = .kelvin; r.kelvin = 5200
        let codes = PresetCodec.encode(r).map(\.code)
        let i = try! XCTUnwrap(codes.firstIndex(of: FujiProp.whiteBalance))
        XCTAssertEqual(codes[i + 1], FujiProp.wbColorTemp)
    }

    func testMonochromeSkipsColorAndZeroMono() {
        var r = kodachrome(); r.filmSimulation = .acrosRed; r.monoWarmCool = 3; r.monoMagentaGreen = 0
        let w = dict(PresetCodec.encode(r))
        XCTAssertNil(w[FujiProp.color])
        XCTAssertEqual(u16(w[FujiProp.monoWarmCool]), 30)
        XCTAssertNil(w[FujiProp.monoMagentaGreen])
    }

    func testUneditedPropertiesSkippedWhenSlotWasRead() {
        var b = ByteWriter(); b.u16(1)
        let base = [FujiProp.imageQuality: b.data, FujiProp.longExposureNR: b.data]
        let w = dict(PresetCodec.encode(kodachrome(), base: base))
        XCTAssertNil(w[FujiProp.imageQuality])
        XCTAssertNil(w[FujiProp.longExposureNR])
        XCTAssertEqual(u16(w[FujiProp.imageSize]), 7, "no base value: default is written")
    }

    func testDynamicRangeAuto() {
        var r = kodachrome(); r.dynamicRange = .auto
        let w = dict(PresetCodec.encode(r))
        XCTAssertEqual(u16(w[FujiProp.dynamicRange]), 0xFFFF)
        let back = PresetCodec.decode(CameraPreset(slot: 4, name: r.name, raw: w))
        XCTAssertEqual(back.dynamicRange, .auto)
        XCTAssertEqual(RecipeText.parse("X\nDynamic Range: DR-Auto").recipe.dynamicRange, .auto)
    }

    func testDecodeRoundTrip() {
        for sim in FilmSimulation.allCases {
            var r = kodachrome(); r.filmSimulation = sim
            if sim.isMonochrome { r.monoWarmCool = -2; r.monoMagentaGreen = 4 }
            let raw = dict(PresetCodec.encode(r))
            let back = PresetCodec.decode(CameraPreset(slot: 3, name: r.name, raw: raw))
            XCTAssertTrue(back.sameSettings(as: r), "\(sim)")
        }
    }

    func testServiceWritesAndVerifies() async throws {
        let s = MockStream()
        let cam = FakeCamera()
        cam.attach(to: s)
        let service = PresetService(session: PTPSession(transport: StreamPTPTransport(stream: s)))
        let report = try await service.write(kodachrome(), to: 4)
        XCTAssertTrue(report.ok, report.rejected.joined(separator: "\n"))
        XCTAssertEqual(cam.names[4], "Kodachrome 64")
        let read = try await service.readSlot(4)
        XCTAssertTrue(PresetCodec.decode(read).sameSettings(as: kodachrome()))
    }

    func testServiceReportsRejectedProperty() async throws {
        let s = MockStream()
        let cam = FakeCamera()
        cam.rejects = [FujiProp.clarity]
        cam.attach(to: s)
        let service = PresetService(session: PTPSession(transport: StreamPTPTransport(stream: s)))
        let report = try await service.write(kodachrome(), to: 1)
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.rejected.count, 1)
        XCTAssertTrue(report.rejected[0].hasPrefix("0xD1A2"))
    }
}

final class RecipeTextTests: XCTestCase {
    let sample = """
    Kodachrome 64
    Film Simulation: Classic Chrome
    Grain Effect: Weak, Small
    Color Chrome Effect: Strong
    Color Chrome FX Blue: Weak
    White Balance: Daylight, +2 Red & -5 Blue
    Dynamic Range: DR200
    Highlight: 0
    Shadow: +0.5
    Color: +2
    Sharpness: +1
    High ISO NR: -4
    Clarity: +3
    ISO: Auto, up to ISO 6400
    Exposure Compensation: 0 to +1/3 (typically)
    """

    func testParsesFujiXWeeklyStyle() {
        let p = RecipeText.parse(sample)
        XCTAssertEqual(p.unrecognized, [])
        let r = p.recipe
        XCTAssertEqual(r.name, "Kodachrome 64")
        XCTAssertEqual(r.filmSimulation, .classicChrome)
        XCTAssertEqual(r.grain, .weakSmall)
        XCTAssertEqual(r.colorChrome, .strong)
        XCTAssertEqual(r.colorChromeBlue, .weak)
        XCTAssertEqual(r.whiteBalance, .daylight)
        XCTAssertEqual(r.wbShiftRed, 2)
        XCTAssertEqual(r.wbShiftBlue, -5)
        XCTAssertEqual(r.dynamicRange, .dr200)
        XCTAssertEqual(r.shadow, 0.5)
        XCTAssertEqual(r.color, 2)
        XCTAssertEqual(r.noiseReduction, -4)
        XCTAssertEqual(r.clarity, 3)
        XCTAssertEqual(r.isoNote, "Auto, up to ISO 6400")
    }

    func testFormatThenParseIsStable() {
        let r = RecipeText.parse(sample).recipe
        let again = RecipeText.parse(RecipeText.format(r)).recipe
        XCTAssertTrue(again.sameSettings(as: r))
        XCTAssertEqual(again.name, r.name)
    }

    func testKelvinAndFilters() {
        let r = RecipeText.parse("""
        Film Simulation: Acros+R
        White Balance: 5200K, -1 Red & +3 Blue
        Monochromatic Color: +2 WC & -1 MG
        """).recipe
        XCTAssertEqual(r.filmSimulation, .acrosRed)
        XCTAssertEqual(r.whiteBalance, .kelvin)
        XCTAssertEqual(r.kelvin, 5200)
        XCTAssertEqual(r.wbShiftRed, -1)
        XCTAssertEqual(r.wbShiftBlue, 3)
        XCTAssertEqual(r.monoWarmCool, 2)
        XCTAssertEqual(r.monoMagentaGreen, -1)
    }

    func testSimulationNames() {
        let cases: [(String, FilmSimulation)] = [
            ("Classic Negative", .classicNeg), ("Eterna Bleach Bypass", .eternaBleachBypass),
            ("PRO Neg. Std", .proNegStd), ("Pro Neg Hi", .proNegHi), ("Velvia", .velvia),
            ("Acros", .acros), ("Acros + Ye Filter", .acrosYellow), ("Monochrome+G", .monochromeGreen),
            ("Provia/Standard", .provia), ("Astia/Soft", .astia), ("Sepia", .sepia),
        ]
        for (text, sim) in cases {
            XCTAssertEqual(RecipeText.filmSimulation(text.lowercased()), sim, text)
        }
    }

    func testBundleRoundTripAndTextFallback() throws {
        let r = RecipeText.parse(sample).recipe
        let data = try RecipeBundle(recipes: [r, r]).encoded()
        XCTAssertEqual(RecipeBundle.importAny(data).count, 2)
        let text = [sample, RecipeText.format(r)].joined(separator: RecipeText.separator)
        XCTAssertEqual(RecipeBundle.importAny(Data(text.utf8)).count, 2)
    }
}

final class WirelessTests: XCTestCase {
    func testGeotagPacket() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8, minute: 30, second: 5))!
        let p = FujiBLE.geotagPacket(latitude: 41.0082, longitude: 28.9784, altitude: 39.6, date: date)
        XCTAssertEqual(p.count, 23)
        var r = ByteReader(p)
        XCTAssertEqual(try r.i32(), 410_082_000)
        XCTAssertEqual(try r.i32(), 289_784_000)
        XCTAssertEqual(try r.i32(), 40)
        _ = try? r.bytes(4)
        XCTAssertEqual(try r.u16(), 2026)
        XCTAssertEqual(Array(r.rest()), [11, 1, 8, 30, 5])
    }

    func testAdvertisementParsing() {
        let legacy = Data([0xD8, 0x04, 0x02, 0xAA, 0xBB, 0xCC, 0xDD])
        XCTAssertEqual(FujiBLE.parseAdvertisement(manufacturerData: legacy, advertisedServices: []),
                       .legacy(token: Data([0xAA, 0xBB, 0xCC, 0xDD])))
        let secure = Data([0xD8, 0x04, 0x01, 1, 2, 3, 4, 5])
        XCTAssertEqual(FujiBLE.parseAdvertisement(manufacturerData: secure, advertisedServices: [FujiBLE.Service.secureAdvertised]),
                       .secure(serial: Data([1, 2, 3, 4, 5])))
        XCTAssertNil(FujiBLE.parseAdvertisement(manufacturerData: Data([0x4C, 0x00, 0x02, 1, 2, 3, 4]), advertisedServices: []))
    }

    func testInitPacket() {
        let p = FujiWiFi.initPacket(clientName: "resync")
        XCTAssertEqual(p.count, 82)
        XCTAssertEqual(Array(p.prefix(12)), [0x52, 0, 0, 0, 1, 0, 0, 0, 0xF2, 0xE4, 0x53, 0x8F])
        XCTAssertEqual(Array(p[28 ..< 32]), [0x72, 0, 0x65, 0]) // "re"
    }

    func testEventsParsing() {
        var w = ByteWriter(); w.u16(2); w.u16(0xDF00); w.u32(6); w.u16(0xD222); w.u32(42)
        let e = FujiWiFi.parseEvents(w.data)
        XCTAssertEqual(e[0xDF00], 6)
        XCTAssertEqual(e[0xD222], 42)
    }

    func testLiveViewHeader() {
        var w = ByteWriter(); w.u32(18 + 1000); w.bytes(Data(count: 14))
        XCTAssertEqual(FujiWiFi.liveViewFrameLength(header: w.data), 1000)
        XCTAssertNil(FujiWiFi.liveViewFrameLength(header: Data([1, 0, 0, 0])))
    }
}
