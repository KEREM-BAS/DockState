import Foundation
@testable import DockStateCore

enum Fixtures {
    static func display(
        _ id: String, uuid: String? = nil, vendor: UInt32 = 0x10AC, model: UInt32 = 0xA0B1, serial: UInt32 = 0,
        name: String = "Display", builtin: Bool = false, main: Bool = false,
        x: Double, y: Double = 0, w: Double = 1920, h: Double = 1080, scale: Double = 1
    ) -> DisplayDescriptor {
        let frame = Frame(x: x, y: y, width: w, height: h)
        return DisplayDescriptor(
            id: id, uuid: uuid ?? id, vendorID: vendor, modelID: model, serialNumber: serial, name: name,
            isBuiltin: builtin, isMain: main, frame: frame,
            visibleFrame: Frame(x: x, y: y + (main ? 25 : 0), width: w, height: h - (main ? 25 : 0)),
            pixelWidth: Int(w * scale), pixelHeight: Int(h * scale), scale: scale)
    }

    static let macbook = display(
        "MB", vendor: 0x610, model: 0xA050, name: "Built-in Retina Display", builtin: true, main: false,
        x: -1512, y: 300, w: 1512, h: 982, scale: 2)
    static let lg = display(
        "LG", vendor: 0x1E6D, model: 0x5B71, serial: 0x1234, name: "LG UltraFine", main: true,
        x: 0, y: 0, w: 2560, h: 1440, scale: 2)
    static let dell = display("DELL", vendor: 0x10AC, model: 0xA0B1, serial: 0, name: "DELL P2419H", x: 2560, y: 200)

    static let homeDisplays = [macbook, lg, dell]

    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DockStateTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
