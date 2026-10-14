import Flutter
import UIKit
import StarIO10

/// flutter_star_prnt_plus re-implemented on Star's StarXpand SDK (StarIO10).
/// Keeps the original MethodChannel contract ('flutter_star_prnt':
/// portDiscovery / checkStatus / print) so the Dart API is unchanged.
public class FlutterStarPrntPlugin: NSObject, FlutterPlugin {
    // Delegate lives in a non-public helper so StarIO10 types don't leak into the
    // generated Objective-C header (which would fail to compile in the host app).
    private lazy var discoveryDelegate = DiscoveryDelegate(owner: self)
    private var discoveryManager: (any StarDeviceDiscoveryManager)?
    private var discoveryResult: FlutterResult?
    private var discovered: [[String: Any]] = []

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_star_prnt", binaryMessenger: registrar.messenger())
        let instance = FlutterStarPrntPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "portDiscovery":
            portDiscovery(type: args["type"] as? String ?? "All", result: result)
        case "checkStatus":
            checkStatus(portName: args["portName"] as? String ?? "", result: result)
        case "print":
            printCommands(portName: args["portName"] as? String ?? "",
                          commands: args["printCommands"] as? [[String: Any]] ?? [],
                          result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Discovery

    private func portDiscovery(type: String, result: @escaping FlutterResult) {
        let interfaces: [InterfaceType]
        switch type {
        case "LAN": interfaces = [.lan]
        case "Bluetooth": interfaces = [.bluetooth, .bluetoothLE]
        case "USB": interfaces = [.usb]
        default: interfaces = [.lan, .bluetooth, .bluetoothLE, .usb]
        }
        discoveryManager?.stopDiscovery()
        if let pending = discoveryResult { pending(discovered) }
        discovered = []
        discoveryResult = result
        do {
            let manager = try StarDeviceDiscoveryManagerFactory.create(interfaceTypes: interfaces)
            manager.discoveryTime = interfaces.contains(.bluetoothLE) ? 10000 : (interfaces.contains(.lan) ? 5000 : 2000)
            manager.delegate = discoveryDelegate
            discoveryManager = manager
            try manager.startDiscovery()
        } catch {
            discoveryResult = nil
            result(FlutterError(code: "PORT_DISCOVERY_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private static func prefix(_ t: InterfaceType) -> String {
        switch t {
        case .lan: return "TCP:"
        case .bluetooth: return "BT:"
        case .bluetoothLE: return "BLE:"
        case .usb: return "USB:"
        default: return ""
        }
    }

    fileprivate func didFind(_ printer: StarPrinter) {
        let s = printer.connectionSettings
        var m: [String: Any] = [
            "portName": FlutterStarPrntPlugin.prefix(s.interfaceType) + s.identifier,
            "modelName": printer.information?.model.description ?? "Unknown",
            "interfaceType": s.interfaceType.description,
        ]
        if let e = printer.information?.emulation.description { m["emulation"] = e }
        if let mac = printer.information?.detail.lan.macAddress { m["macAddress"] = mac }
        if let sn = printer.information?.detail.usb.usbSerialNumber { m["USBSerialNumber"] = sn }
        DispatchQueue.main.async { self.discovered.append(m) }
    }

    fileprivate func didFinishDiscovery() {
        DispatchQueue.main.async {
            self.discoveryResult?(self.discovered)
            self.discoveryResult = nil
        }
    }

    // MARK: - Connection

    private func connectionSettings(_ portName: String) -> StarConnectionSettings {
        var prefix = ""
        var rest = portName
        if let idx = portName.firstIndex(of: ":") {
            prefix = String(portName[..<idx]).uppercased()
            rest = String(portName[portName.index(after: idx)...])
        }
        switch prefix {
        case "TCP", "LAN": return StarConnectionSettings(interfaceType: .lan, identifier: rest)
        case "BT": return StarConnectionSettings(interfaceType: .bluetooth, identifier: rest)
        case "BLE": return StarConnectionSettings(interfaceType: .bluetoothLE, identifier: rest)
        case "USB": return StarConnectionSettings(interfaceType: .usb, identifier: rest)
        default: return StarConnectionSettings(interfaceType: .lan, identifier: portName)
        }
    }

    private func checkStatus(portName: String, result: @escaping FlutterResult) {
        let printer = StarPrinter(connectionSettings(portName))
        Task {
            var map: [String: Any] = [:]
            do {
                try await printer.open()
                let status = try await printer.getStatus()
                map["is_success"] = true
                map["offline"] = false
                map["coverOpen"] = status.coverOpen
                map["receiptPaperEmpty"] = status.paperEmpty
                map["receiptPaperNearEmpty"] = status.paperNearEmpty
                map["cutterError"] = false
                map["overTemp"] = false
                map["hasError"] = status.hasError
                map["drawerOpenCloseSignal"] = status.drawerOpenCloseSignal
                if let model = printer.information?.model.description { map["ModelName"] = model }
            } catch {
                map["is_success"] = false
                map["offline"] = true
                map["error_message"] = error.localizedDescription
            }
            await printer.close()
            let reply = map
            DispatchQueue.main.async { result(reply) }
        }
    }

    private func printCommands(portName: String, commands: [[String: Any]], result: @escaping FlutterResult) {
        let printer = StarPrinter(connectionSettings(portName))
        Task {
            var map: [String: Any] = [:]
            do {
                let job = try await Task.detached { try CommandMapper.build(commands) }.value
                try await printer.open()
                try await printer.print(command: job)
                map["is_success"] = true
                map["offline"] = false
                map["info_message"] = "Success"
                if let status = try? await printer.getStatus() {
                    map["coverOpen"] = status.coverOpen
                    map["receiptPaperEmpty"] = status.paperEmpty
                }
            } catch {
                map["is_success"] = false
                map["offline"] = true
                map["error_message"] = error.localizedDescription
            }
            await printer.close()
            let reply = map
            DispatchQueue.main.async { result(reply) }
        }
    }
}

final class DiscoveryDelegate: NSObject, StarDeviceDiscoveryManagerDelegate {
    private weak var owner: FlutterStarPrntPlugin?
    init(owner: FlutterStarPrntPlugin) { self.owner = owner }
    func manager(_ manager: any StarDeviceDiscoveryManager, didFind printer: StarPrinter) {
        owner?.didFind(printer)
    }
    func managerDidFinishDiscovery(_ manager: any StarDeviceDiscoveryManager) {
        owner?.didFinishDiscovery()
    }
}

// MARK: - Legacy command list -> StarXpand command

enum CommandMapper {
    typealias P = StarXpandCommand.PrinterBuilder

    static func build(_ commands: [[String: Any]]) throws -> String {
        let document = StarXpandCommand.DocumentBuilder()
        var printer = P()
        var used = false
        func flush() {
            if used { _ = document.addPrinter(printer) }
            printer = P()
            used = false
        }

        for c in commands {
            used = true
            if c["appendEncoding"] != nil || c["appendCodePage"] != nil {
                // StarIO10 sends text as Unicode and selects code pages itself.
            } else if let v = c["appendCharacterSpace"] {
                _ = printer.styleCharacterSpace(mm(v))
            } else if let v = c["append"] ?? c["appendRaw"] {
                let text = "\(v)"
                if let a = c["alignment"] as? String {
                    _ = printer.add(P().styleAlignment(alignment(a)).actionPrintText(text))
                } else {
                    _ = printer.actionPrintText(text)
                }
            } else if let v = c["appendMultiple"] {
                let w = int(c["width"], 2), h = int(c["height"], 2)
                _ = printer.add(P().styleMagnification(StarXpandCommand.MagnificationParameter(width: w, height: h)).actionPrintText("\(v)"))
            } else if let v = c["appendEmphasis"] {
                _ = printer.add(P().styleBold(true).actionPrintText("\(v)"))
            } else if let v = c["enableEmphasis"] {
                _ = printer.styleBold(bool(v, true))
            } else if let v = c["appendInvert"] {
                _ = printer.add(P().styleInvert(true).actionPrintText("\(v)"))
            } else if let v = c["enableInvert"] {
                _ = printer.styleInvert(bool(v, true))
            } else if let v = c["appendUnderline"] {
                _ = printer.add(P().styleUnderLine(true).actionPrintText("\(v)"))
            } else if let v = c["enableUnderline"] {
                _ = printer.styleUnderLine(bool(v, true))
            } else if let v = c["appendInternational"] as? String {
                if let t = international(v) { _ = printer.styleInternationalCharacter(t) }
            } else if let v = c["appendLineFeed"] {
                _ = printer.actionFeedLine(int(v, 1))
            } else if let v = c["appendUnitFeed"] {
                _ = printer.actionFeed(mm(v))
            } else if let v = c["appendLineSpace"] {
                _ = printer.styleLineSpace(mm(v))
            } else if let v = c["appendFontStyle"] as? String {
                _ = printer.styleFont(v == "B" ? .b : .a)
            } else if let v = c["appendCutPaper"] as? String {
                _ = printer.actionCut(cutType(v))
            } else if let v = c["openCashDrawer"] {
                flush()
                let ch: StarXpandCommand.Drawer.Channel = int(v, 1) == 2 ? .no2 : .no1
                _ = document.addDrawer(StarXpandCommand.DrawerBuilder()
                    .actionOpen(StarXpandCommand.Drawer.OpenParameter().setChannel(ch)))
            } else if let v = c["appendBytes"] ?? c["appendRawBytes"] {
                flush()
                _ = document.addRaw(bytes(v))
            } else if let v = c["appendAbsolutePosition"] {
                _ = printer.styleHorizontalPositionTo(mm(v))
                if let d = c["data"] { _ = printer.actionPrintText("\(d)") }
            } else if let v = c["appendAlignment"] as? String {
                if let d = c["data"] {
                    _ = printer.add(P().styleAlignment(alignment(v)).actionPrintText("\(d)"))
                } else {
                    _ = printer.styleAlignment(alignment(v))
                }
            } else if let v = c["appendLogo"] {
                _ = printer.actionPrintLogo(StarXpandCommand.Printer.LogoParameter(keyCode: "\(v)"))
            } else if let v = c["appendBarcode"] {
                let p = StarXpandCommand.Printer.BarcodeParameter(content: "\(v)", symbology: symbology(c["BarcodeSymbology"] as? String))
                    .setPrintHRI(bool(c["hri"], true))
                    .setHeight(mm(c["height"] ?? 40))
                if let w = c["BarcodeWidth"] as? String, let n = Int(w.replacingOccurrences(of: "Mode", with: "")) {
                    _ = p.setBarDots(((n - 1) % 3) + 1)
                }
                _ = printer.add(positioned(c).actionPrintBarcode(p))
            } else if let v = c["appendQrCode"] {
                let p = StarXpandCommand.Printer.QRCodeParameter(content: "\(v)")
                    .setModel((c["QrCodeModel"] as? String) == "No1" ? .model1 : .model2)
                    .setLevel(qrLevel(c["QrCodeLevel"] as? String))
                    .setCellSize(int(c["cell"], 4))
                _ = printer.add(positioned(c).actionPrintQRCode(p))
            } else if let v = c["appendBitmap"] as? String {
                if let img = loadImage(v) { appendImage(printer, img, c) } else { NSLog("FlutterStarPrnt: cannot load image \(v)") }
            } else if let v = c["appendBitmapByteArray"] {
                if let img = UIImage(data: bytes(v)) { appendImage(printer, img, c) } else { NSLog("FlutterStarPrnt: cannot decode image bytes") }
            } else if let v = c["appendBitmapText"] {
                let size = CGFloat(double(c["fontSize"], 25))
                let width = CGFloat(int(c["width"], 576))
                let font = UIFont(name: "Menlo", size: size) ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
                if let img = imageWithString("\(v)", font: font, width: width) { appendImage(printer, img, c) }
            } else {
                NSLog("FlutterStarPrnt: unsupported command ignored: \(Array(c.keys))")
            }
        }
        flush()
        return StarXpandCommand.StarXpandCommandBuilder().addDocument(document).getCommands()
    }

    private static func positioned(_ c: [String: Any]) -> P {
        let b = P()
        if let a = c["alignment"] as? String { _ = b.styleAlignment(alignment(a)) }
        if let x = c["absolutePosition"] { _ = b.styleHorizontalPositionTo(mm(x)) }
        return b
    }

    private static func appendImage(_ printer: P, _ source: UIImage, _ c: [String: Any]) {
        let width = int(c["width"], 576)
        let img = rotate(source, c["rotation"] as? String)
        let both = bool(c["bothScale"], true)
        let pixelWidth = Int(img.size.width * img.scale)
        let target = both ? width : min(width, pixelWidth)
        let param = StarXpandCommand.Printer.ImageParameter(image: img, width: target)
            .setEffectDiffusion(bool(c["diffusion"], true))
        _ = printer.add(positioned(c).actionPrintImage(param))
    }

    private static func rotate(_ img: UIImage, _ rotation: String?) -> UIImage {
        let angle: CGFloat
        switch rotation {
        case "Left90": angle = -.pi / 2
        case "Right90": angle = .pi / 2
        case "Rotate180": angle = .pi
        default: return img
        }
        var size = CGRect(origin: .zero, size: img.size).applying(CGAffineTransform(rotationAngle: angle)).size
        size = CGSize(width: abs(size.width).rounded(), height: abs(size.height).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = img.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.cgContext.rotate(by: angle)
            img.draw(in: CGRect(x: -img.size.width / 2, y: -img.size.height / 2, width: img.size.width, height: img.size.height))
        }
    }

    private static func loadImage(_ path: String) -> UIImage? {
        if path.hasPrefix("http://") || path.hasPrefix("https://"), let url = URL(string: path),
           let data = try? Data(contentsOf: url) {
            return UIImage(data: data)
        }
        let p = path.hasPrefix("file://") ? String(path.dropFirst(7)) : path
        return UIImage(contentsOfFile: p)
    }

    private static func imageWithString(_ string: String, font: UIFont, width: CGFloat) -> UIImage? {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
        let rect = (string as NSString).boundingRect(with: CGSize(width: width, height: 100000),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                     attributes: attrs, context: nil)
        let size = CGSize(width: width, height: max(1, ceil(rect.height)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            (string as NSString).draw(in: CGRect(origin: .zero, size: size), withAttributes: attrs)
        }
    }

    // Helpers. The legacy API used printer dots (203 dpi ≈ 8 dots/mm); StarIO10 uses mm.
    private static func mm(_ v: Any?) -> Double { double(v, 0) / 8.0 }
    private static func double(_ v: Any?, _ d: Double) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String, let n = Double(s) { return n }
        return d
    }
    private static func int(_ v: Any?, _ d: Int) -> Int { v == nil ? d : Int(double(v, Double(d))) }
    private static func bool(_ v: Any?, _ d: Bool) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return s.lowercased() == "true" ? true : (s.lowercased() == "false" ? false : d) }
        return d
    }
    private static func bytes(_ v: Any) -> Data {
        if let t = v as? FlutterStandardTypedData { return t.data }
        if let a = v as? [NSNumber] { return Data(a.map { UInt8(truncatingIfNeeded: $0.intValue) }) }
        if let s = v as? String { return Data(s.utf8) }
        return Data()
    }
    private static func alignment(_ s: String) -> StarXpandCommand.Printer.Alignment {
        s == "Center" ? .center : (s == "Right" ? .right : .left)
    }
    private static func cutType(_ s: String) -> StarXpandCommand.Printer.CutType {
        switch s {
        case "FullCut": return .fullDirect
        case "PartialCut": return .partialDirect
        case "PartialCutWithFeed": return .partial
        default: return .full
        }
    }
    private static func international(_ s: String) -> StarXpandCommand.Printer.InternationalCharacterType? {
        switch s {
        case "UK": return .uk
        case "USA": return .usa
        case "France": return .france
        case "Germany": return .germany
        case "Denmark": return .denmark
        case "Sweden": return .sweden
        case "Italy": return .italy
        case "Spain": return .spain
        case "Japan": return .japan
        case "Norway": return .norway
        case "Denmark2": return .denmark2
        case "Spain2": return .spain2
        case "LatinAmerica": return .latinAmerica
        case "Korea": return .korea
        case "Ireland": return .ireland
        case "Legal": return .legal
        default: return nil
        }
    }
    private static func symbology(_ s: String?) -> StarXpandCommand.Printer.BarcodeSymbology {
        switch s {
        case "Code39": return .code39
        case "Code93": return .code93
        case "ITF": return .itf
        case "JAN8": return .jan8
        case "JAN13": return .jan13
        case "NW7": return .nw7
        case "UPCA": return .upcA
        case "UPCE": return .upcE
        default: return .code128
        }
    }
    private static func qrLevel(_ s: String?) -> StarXpandCommand.Printer.QRCodeLevel {
        switch s {
        case "H": return .h
        case "M": return .m
        case "Q": return .q
        default: return .l
        }
    }
}
