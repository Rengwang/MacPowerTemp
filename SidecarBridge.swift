import AppKit
import CoreGraphics
import Foundation

/// Detected landscape Sidecar display parameters and derived portrait HiDPI presets.
struct SidecarMetrics: Equatable {
    let displayID: CGDirectDisplayID
    let deviceName: String
    let landscapePoints: CGSize
    let landscapePixels: CGSize
    let scale: CGFloat
    let refreshRate: Double

    /// Physical pixels turned sideways for portrait capture (1:1 pixel match with iPad panel).
    var portraitCapturePixels: CGSize {
        CGSize(width: landscapePixels.height, height: landscapePixels.width)
    }

    /// Native 1:1 portrait logical points.
    var nativePortraitPoints: CGSize {
        CGSize(width: landscapePoints.height, height: landscapePoints.width)
    }

    /// Aspect-ratio-preserving portrait HiDPI presets derived from the active iPad model.
    func portraitPresets() -> [PortraitPreset] {
        let baseW = Double(nativePortraitPoints.width)
        let baseH = Double(nativePortraitPoints.height)
        let aspect = baseH / max(baseW, 1.0)

        let scales: [(short: String, full: String, factor: Double)] = [
            ("更大字体", "更大字体 (0.75x)", 0.75),
            ("原生 1:1", "原生点对点 (1.0x)", 1.0),
            ("更多空间", "更多空间 (1.2x)", 1.2),
            ("超大空间", "超大空间 (1.4x)", 1.4),
        ]

        return scales.map { item in
            let w: Int
            let h: Int
            if item.factor == 1.0 {
                w = Int(baseW.rounded())
                h = Int(baseH.rounded())
            } else {
                w = Self.roundToEven(baseW * item.factor)
                h = Self.roundToEven(Double(w) * aspect)
            }
            return PortraitPreset(
                shortTitle: item.short,
                title: "\(item.full) · \(w)×\(h)",
                size: CGSize(width: w, height: h)
            )
        }
    }

    /// Computes non-overlapping display origins: virtual portrait next to main display,
    /// hidden landscape Sidecar parked diagonally opposite so cursor cannot wander into it.
    func computeDisplayOrigins(
        mainBounds: CGRect,
        virtualID: CGDirectDisplayID,
        portraitSize: CGSize,
        placeOnLeft: Bool
    ) -> [(CGDirectDisplayID, Int32, Int32)] {
        let mainW = Int32(mainBounds.width)
        let mainMinX = Int32(mainBounds.minX)
        let mainMinY = Int32(mainBounds.minY)
        let vW = Int32(portraitSize.width)
        let sW = Int32(landscapePoints.width)
        let sH = Int32(landscapePoints.height)

        if placeOnLeft {
            return [
                (virtualID, mainMinX - vW, mainMinY),
                (displayID, mainMinX + mainW, mainMinY - sH),
            ]
        } else {
            return [
                (virtualID, mainMinX + mainW, mainMinY),
                (displayID, mainMinX - sW, mainMinY - sH),
            ]
        }
    }

    private static func roundToEven(_ value: Double) -> Int {
        let rounded = Int((value / 2.0).rounded()) * 2
        return max(rounded, 200)
    }
}

struct PortraitPreset: Equatable {
    let shortTitle: String
    let title: String
    let size: CGSize
}

/// Lightweight wrapper over Apple's private SidecarCore.framework (`SidecarDisplayManager`).
/// Pattern inspired by ipad-vertical (MIT) and StripRotate (MIT).
enum SidecarBridge {
    private static let appleVendorID: UInt32 = 0x6161_706c // 'aapl'
    private static let ipadProductID: UInt32 = 0x6950_6164 // 'iPad'

    private static let manager: NSObject? = {
        dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_NOW)
        guard let cls = NSClassFromString("SidecarDisplayManager") as? NSObject.Type else {
            return nil
        }
        return cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject
    }()

    static func devices() -> [NSObject] {
        (manager?.perform(NSSelectorFromString("devices"))?.takeUnretainedValue() as? [NSObject]) ?? []
    }

    static func connectedDevices() -> [NSObject] {
        (manager?.perform(NSSelectorFromString("connectedDevices"))?.takeUnretainedValue() as? [NSObject]) ?? []
    }

    static func connectedDeviceName() -> String? {
        guard let dev = connectedDevices().first else { return nil }
        let name = (dev.value(forKey: "name") as? String) ?? ""
        if !name.isEmpty { return name }
        return (dev.value(forKey: "model") as? String) ?? "iPad"
    }

    static func availableDeviceName() -> String? {
        guard let dev = (connectedDevices().first ?? devices().first) else { return nil }
        let name = (dev.value(forKey: "name") as? String) ?? ""
        if !name.isEmpty { return name }
        return (dev.value(forKey: "model") as? String) ?? "iPad"
    }

    static func connect(completion: @escaping (Bool) -> Void) {
        callDeviceSelector("connectToDevice:completion:", completion: completion)
    }

    static func disconnect(completion: @escaping (Bool) -> Void) {
        callDeviceSelector("disconnectFromDevice:completion:", completion: completion)
    }

    private static func callDeviceSelector(_ selectorName: String, completion: @escaping (Bool) -> Void) {
        guard let manager, let device = (connectedDevices().first ?? devices().first) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        let block: @convention(block) (NSError?) -> Void = { err in
            DispatchQueue.main.async { completion(err == nil) }
        }
        _ = manager.perform(NSSelectorFromString(selectorName), with: device, with: block)
    }

    /// Identifies the active Sidecar NSScreen, excluding our own virtual portrait display.
    static func findSidecarScreen(excludingVirtualID virtualID: CGDirectDisplayID) -> NSScreen? {
        let candidates = NSScreen.screens.filter { screen in
            let id = displayID(of: screen)
            return id != 0 && id != virtualID && CGDisplayIsBuiltin(id) == 0 && screen.localizedName != "Sidecar Vertical"
        }

        if let exact = candidates.first(where: { screen in
            let id = displayID(of: screen)
            return CGDisplayVendorNumber(id) == appleVendorID && CGDisplayModelNumber(id) == ipadProductID
        }) {
            return exact
        }

        return candidates.first { screen in
            let name = screen.localizedName.lowercased()
            return name.contains("sidecar") || name.contains("ipad")
        }
    }

    static func detectMetrics(excludingVirtualID virtualID: CGDirectDisplayID) -> SidecarMetrics? {
        guard let screen = findSidecarScreen(excludingVirtualID: virtualID) else { return nil }
        let id = displayID(of: screen)
        let mode = CGDisplayCopyDisplayMode(id)
        let pxW = mode.map { CGFloat($0.pixelWidth) } ?? CGFloat(CGDisplayPixelsWide(id))
        let pxH = mode.map { CGFloat($0.pixelHeight) } ?? CGFloat(CGDisplayPixelsHigh(id))
        let refresh = (mode?.refreshRate ?? 0) > 0 ? mode!.refreshRate : 60.0
        let scale = max(screen.backingScaleFactor, 1.0)
        let name = connectedDeviceName() ?? screen.localizedName

        return SidecarMetrics(
            displayID: id,
            deviceName: name,
            landscapePoints: screen.frame.size,
            landscapePixels: CGSize(width: pxW, height: pxH),
            scale: scale,
            refreshRate: refresh
        )
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Pure coordinate and delta transforms mapping hidden landscape Sidecar input
/// onto the rotated portrait virtual display in global Quartz coordinates.
enum SidecarInputTransform {
    /// Maps a Quartz global point from the hidden landscape Sidecar display
    /// into the rotated portrait virtual display bounds.
    static func mapPoint(
        _ point: CGPoint,
        from hiddenBounds: CGRect,
        to virtualBounds: CGRect,
        rotationDegrees: Int
    ) -> CGPoint {
        guard hiddenBounds.width > 0, hiddenBounds.height > 0,
              virtualBounds.width > 0, virtualBounds.height > 0 else {
            return point
        }

        let u = min(max((point.x - hiddenBounds.minX) / hiddenBounds.width, 0.0), 1.0)
        let v = min(max((point.y - hiddenBounds.minY) / hiddenBounds.height, 0.0), 1.0)

        let nx: CGFloat
        let ny: CGFloat
        if rotationDegrees == 270 {
            // contentLayer rotated +pi/2 (landscape left -> portrait top)
            nx = 1.0 - v
            ny = u
        } else {
            // contentLayer rotated -pi/2 (landscape right -> portrait top)
            nx = v
            ny = 1.0 - u
        }

        let epsX = min(0.5, virtualBounds.width * 0.5)
        let epsY = min(0.5, virtualBounds.height * 0.5)
        let vx = min(max(virtualBounds.minX + nx * virtualBounds.width, virtualBounds.minX), virtualBounds.maxX - epsX)
        let vy = min(max(virtualBounds.minY + ny * virtualBounds.height, virtualBounds.minY), virtualBounds.maxY - epsY)
        return CGPoint(x: vx, y: vy)
    }

    /// Rotates a Quartz top-down 2D displacement vector (dx, dy) from landscape to portrait.
    static func rotateVector(_ dx: Double, _ dy: Double, rotationDegrees: Int) -> (Double, Double) {
        rotationDegrees == 270 ? (-dy, dx) : (dy, -dx)
    }

    /// Rotates CoreGraphics scroll axes (axis1 = vertical, axis2 = horizontal).
    static func rotateScrollAxes(
        axis1: Double,
        axis2: Double,
        rotationDegrees: Int
    ) -> (axis1: Double, axis2: Double) {
        rotationDegrees == 270 ? (axis2, -axis1) : (-axis2, axis1)
    }

    /// Integer variant for CoreGraphics integer scroll delta fields.
    static func rotateScrollAxesInt(
        axis1: Int64,
        axis2: Int64,
        rotationDegrees: Int
    ) -> (axis1: Int64, axis2: Int64) {
        rotationDegrees == 270 ? (axis2, -axis1) : (-axis2, axis1)
    }
}
