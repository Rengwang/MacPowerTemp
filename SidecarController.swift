import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import CoreVideo
import Foundation
import os
import QuartzCore
import ScreenCaptureKit

/// Manages portrait Sidecar virtual display, zero-copy ScreenCaptureKit IOSurface capture,
/// rotated fullscreen CALayer overlay, event-driven cursor guard, sleep/lock recovery,
/// and optional global hotkey (Ctrl+Option+V).
final class SidecarController: NSObject, SCStreamOutput, SCStreamDelegate {
    private enum Keys {
        static let rotation = "sidecarVertical.rotationDegrees"
        static let resolutionIndex = "sidecarVertical.resolutionIndex"
        static let placeOnLeft = "sidecarVertical.placeOnLeft"
        static let cursorGuard = "sidecarVertical.cursorGuardEnabled"
        static let hotkeyEnabled = "sidecarVertical.hotkeyEnabled"
        static let accessibilityPrompted = "sidecarVertical.accessibilityPrompted"
    }

    private var virtualDisplay: CGVirtualDisplay?
    private var stream: SCStream?
    private var overlayWindow: SidecarOverlayPanel?
    private let contentLayer = CALayer()
    private let captureQueue = DispatchQueue(label: "com.workbuddy.macpowertemp.sidecar.frames", qos: .userInteractive)
    private let virtualQueue = DispatchQueue(label: "com.workbuddy.macpowertemp.sidecar.virtual", qos: .userInteractive)

    private var mouseMonitor: Any?
    private var lastSafeCursorLocation: CGPoint?
    private var cachedHiddenBounds: CGRect = .null
    private var cachedVirtualBounds: CGRect = .null
    private var cachedMainHeight: CGFloat = 0
    private let touchRemapper = SidecarTouchRemapper()
    private var accessibilityWatchTimer: DispatchSourceTimer?
    private var lastMetrics: SidecarMetrics?
    private var shouldBeVertical = false
    private var recoveryTask: DispatchWorkItem?
    private var systemObserversRegistered = false

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerInstalled = false
    private static weak var hotKeyTarget: SidecarController?

    enum TransitionState: Equatable {
        case idle
        case connectingHorizontal
        case startingVertical
    }

    private(set) var transitionState: TransitionState = .idle
    var isStarting: Bool { transitionState != .idle }
    private(set) var statusText = "快捷键 Ctrl+Opt+V 快速切换横/竖屏"

    var onStateChanged: (() -> Void)?

    var isVertical: Bool { virtualDisplay != nil && stream != nil }
    var hasSidecar: Bool { currentMetrics() != nil }
    var hasScreenCapturePermission: Bool { CGPreflightScreenCaptureAccess() }
    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }
    var isTouchRemappingActive: Bool { touchRemapper.isRunning }

    var resolutionIndex: Int {
        get {
            let idx = UserDefaults.standard.object(forKey: Keys.resolutionIndex) as? Int ?? 1
            let count = currentPresets().count
            return (0..<count).contains(idx) ? idx : min(1, max(count - 1, 0))
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.resolutionIndex) }
    }

    var rotationDegrees: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: Keys.rotation)
            return val == 90 ? 90 : 270
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.rotation) }
    }

    var placeOnLeft: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.placeOnLeft) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.placeOnLeft) }
    }

    var cursorGuardEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Keys.cursorGuard) == nil { return true }
            return UserDefaults.standard.bool(forKey: Keys.cursorGuard)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.cursorGuard)
            if newValue && isVertical && !touchRemapper.isRunning {
                installCursorGuard()
            } else {
                removeCursorGuard()
            }
            notifyStateChanged()
        }
    }

    var hotkeyEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Keys.hotkeyEnabled) == nil { return true }
            return UserDefaults.standard.bool(forKey: Keys.hotkeyEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.hotkeyEnabled)
            syncGlobalHotKey()
            notifyStateChanged()
        }
    }

    deinit {
        if systemObserversRegistered {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
            DistributedNotificationCenter.default().removeObserver(self)
        }
        unregisterGlobalHotKey()
        teardown()
    }

    /// Starts lifecycle observers and hotkey registration only after app launch completes.
    func startLifecycleHooks() {
        registerSystemObserversIfNeeded()
        syncGlobalHotKey()
    }

    func currentMetrics() -> SidecarMetrics? {
        SidecarBridge.detectMetrics(excludingVirtualID: virtualDisplay?.displayID ?? 0)
    }

    func currentPresets() -> [PortraitPreset] {
        if let metrics = currentMetrics() ?? lastMetrics {
            return metrics.portraitPresets()
        }
        let fallback = SidecarMetrics(
            displayID: 0,
            deviceName: "iPad",
            landscapePoints: CGSize(width: 1194, height: 834),
            landscapePixels: CGSize(width: 2388, height: 1668),
            scale: 2.0,
            refreshRate: 60.0
        )
        return fallback.portraitPresets()
    }

    func activeDisplaySummary() -> String? {
        guard isVertical, let vID = virtualDisplay?.displayID else { return nil }
        let mode = CGDisplayCopyDisplayMode(vID)
        let presets = currentPresets()
        let fallback = presets[min(resolutionIndex, presets.count - 1)].size
        let w = mode?.width ?? Int(fallback.width)
        let h = mode?.height ?? Int(fallback.height)
        let isHiDPI = mode.map { $0.pixelWidth > $0.width } ?? true
        return "\(w)×\(h) " + (isHiDPI ? "HiDPI 2x" : "1x")
    }

    // MARK: - Public Controls

    func requestScreenCapturePermission() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        updateStatus("请在「隐私与安全性 → 录屏与系统录音」允许 MacPowerTemp 后重试")
    }

    func requestAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        updateStatus("请在「隐私与安全性 → 辅助功能」允许 MacPowerTemp 以启用竖屏触控")
        if isVertical {
            startAccessibilityWatcherIfNeeded()
        }
    }

    func syncTouchRemapperIfNeeded() {
        guard isVertical else { return }
        if !touchRemapper.isRunning, AXIsProcessTrusted() {
            if let sidecarID = currentMetrics()?.displayID ?? lastMetrics?.displayID {
                refreshGeometryCache(sidecarID: sidecarID)
            }
            if touchRemapper.start() {
                stopAccessibilityWatcher()
                removeCursorGuard()
                overlayWindow?.ignoresMouseEvents = false
                if let sidecarID = currentMetrics()?.displayID ?? lastMetrics?.displayID {
                    refreshGeometryCache(sidecarID: sidecarID)
                }
                if let summary = activeDisplaySummary() {
                    let rate = Int((currentMetrics() ?? lastMetrics)?.refreshRate ?? 60)
                    updateStatus("竖屏 \(summary) @ \(rate)Hz · Ctrl+Opt+V")
                } else {
                    notifyStateChanged()
                }
            } else {
                overlayWindow?.ignoresMouseEvents = !touchRemapper.isRunning
            }
        } else {
            notifyStateChanged()
        }
    }

    func connectHorizontal() {
        if isVertical {
            enableHorizontal()
            return
        }
        guard transitionState == .idle else { return }
        if let metrics = currentMetrics() {
            updateStatus("已连接横屏 · \(Int(metrics.landscapePoints.width))×\(Int(metrics.landscapePoints.height))")
            return
        }
        shouldBeVertical = false
        transitionState = .connectingHorizontal
        updateStatus("正在连接 iPad 横屏随航…")

        ensureSidecarConnected { [weak self] ok in
            guard let self else { return }
            self.transitionState = .idle
            guard ok, let metrics = self.currentMetrics() else {
                self.updateStatus("未检测到随航 iPad，请确认 Wi-Fi/蓝牙已开启或解锁 iPad")
                return
            }
            let bounds = CGDisplayBounds(metrics.displayID)
            let mainBounds = CGDisplayBounds(CGMainDisplayID())
            if bounds.maxY <= mainBounds.minY {
                self.restoreHorizontalOrigin(for: metrics)
            }
            self.updateStatus("已连接横屏 · \(Int(metrics.landscapePoints.width))×\(Int(metrics.landscapePoints.height))")
        }
    }

    func enableVertical() {
        guard !isVertical, transitionState == .idle else { return }
        if !CGPreflightScreenCaptureAccess() {
            requestScreenCapturePermission()
            return
        }
        shouldBeVertical = true
        transitionState = .startingVertical
        updateStatus("正在检测/连接随航 iPad…")

        ensureSidecarConnected { [weak self] ok in
            guard let self else { return }
            guard ok, let metrics = self.currentMetrics() else {
                self.transitionState = .idle
                self.shouldBeVertical = false
                self.updateStatus("未检测到随航 iPad，请确认 Wi-Fi/蓝牙已开启或解锁 iPad")
                return
            }
            self.lastMetrics = metrics
            self.startPipeline(with: metrics)
        }
    }

    func enableHorizontal() {
        shouldBeVertical = false
        transitionState = .idle
        recoveryTask?.cancel()
        teardown()

        ensureSidecarConnected { [weak self] ok in
            guard let self else { return }
            guard ok, let metrics = self.currentMetrics() else {
                self.updateStatus("已关闭竖屏虚拟显示器")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard !self.shouldBeVertical, !self.isVertical else { return }
                self.restoreHorizontalOrigin(for: metrics)
                self.updateStatus("已恢复原生横屏随航")
            }
        }
    }

    func toggle() {
        if isVertical || transitionState == .startingVertical {
            enableHorizontal()
        } else if transitionState == .idle {
            enableVertical()
        }
    }

    func flip180() {
        rotationDegrees = (rotationDegrees == 270) ? 90 : 270
        layoutContentLayer()
        pushTouchGeometry()
        updateStatus(isVertical ? "已旋转 180°（当前 \(rotationDegrees)°）" : "已保存旋转方向（\(rotationDegrees)°）")
    }

    func selectResolution(index: Int) {
        let count = currentPresets().count
        let clamped = min(max(index, 0), max(count - 1, 0))
        resolutionIndex = clamped
        guard isVertical else {
            let preset = currentPresets()[clamped]
            updateStatus("已预设：\(preset.title)")
            return
        }
        updateStatus("正在切换竖屏分辨率…")
        teardown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.enableVertical()
        }
    }

    func togglePlacementSide() {
        placeOnLeft.toggle()
        guard let metrics = currentMetrics() else {
            updateStatus(placeOnLeft ? "已设为在主屏左侧扩展" : "已设为在主屏右侧扩展")
            return
        }
        if isVertical, let v = virtualDisplay {
            let presets = metrics.portraitPresets()
            let preset = presets[min(resolutionIndex, presets.count - 1)]
            let moves = metrics.computeDisplayOrigins(
                mainBounds: CGDisplayBounds(CGMainDisplayID()),
                virtualID: v.displayID,
                portraitSize: preset.size,
                placeOnLeft: placeOnLeft
            )
            Self.applyDisplayOrigins(moves)
            refreshGeometryCache(sidecarID: metrics.displayID)
            updateStatus(placeOnLeft ? "竖屏桌面已移至主屏左侧" : "竖屏桌面已移至主屏右侧")
        } else {
            restoreHorizontalOrigin(for: metrics)
            updateStatus(placeOnLeft ? "横屏桌面已移至主屏左侧" : "横屏桌面已移至主屏右侧")
        }
    }

    func disconnectSidecar() {
        shouldBeVertical = false
        transitionState = .idle
        recoveryTask?.cancel()
        teardown()
        SidecarBridge.disconnect { [weak self] _ in
            self?.updateStatus("已断开随航连接")
        }
    }

    func teardownForAppExit() {
        let wasVertical = isVertical || isStarting || virtualDisplay != nil
        let metrics = currentMetrics() ?? lastMetrics
        shouldBeVertical = false
        transitionState = .idle
        recoveryTask?.cancel()
        teardown()
        if wasVertical, let metrics, SidecarBridge.findSidecarScreen(excludingVirtualID: 0) != nil {
            restoreHorizontalOrigin(for: metrics)
        }
    }

    // MARK: - Pipeline Setup

    private func startPipeline(with metrics: SidecarMetrics) {
        let presets = metrics.portraitPresets()
        let idx = min(resolutionIndex, presets.count - 1)
        let portraitSize = presets[idx].size
        let capturePixels = metrics.portraitCapturePixels

        let preferHiDPI = metrics.scale >= 2.0
        let targetScale: Double = preferHiDPI ? 2.0 : 1.0
        let maxPresetW = presets.map { Double($0.size.width) * targetScale }.max() ?? Double(capturePixels.width)
        let maxPresetH = presets.map { Double($0.size.height) * targetScale }.max() ?? Double(capturePixels.height)
        let maxW = UInt32(max(maxPresetW, Double(capturePixels.width)).rounded(.up))
        let maxH = UInt32(max(maxPresetH, Double(capturePixels.height)).rounded(.up))

        let physMM = CGDisplayScreenSize(metrics.displayID)
        let portraitMM = (physMM.width > 10 && physMM.height > 10)
            ? CGSize(width: min(physMM.width, physMM.height), height: max(physMM.width, physMM.height))
            : CGSize(width: 160, height: 230)

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(virtualQueue)
        descriptor.name = "Sidecar Vertical"
        descriptor.maxPixelsWide = maxW
        descriptor.maxPixelsHigh = maxH
        descriptor.sizeInMillimeters = portraitMM
        descriptor.vendorID = 0x5356 // 'SV'
        descriptor.productID = 0x5031 // 'P1'
        descriptor.serialNum = 1
        descriptor.serialNumber = 1
        // Match Apple iPad Display P3 chromaticity coordinates observed in CoreDisplay.
        descriptor.redPrimary = CGPoint(x: 0.68, y: 0.32)
        descriptor.greenPrimary = CGPoint(x: 0.265, y: 0.69)
        descriptor.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.329)
        descriptor.terminationHandler = { [weak self] _, terminated in
            DispatchQueue.main.async {
                guard let self, self.virtualDisplay === terminated, self.shouldBeVertical else { return }
                self.scheduleRecovery(reason: "虚拟屏已重置，正在重建…")
            }
        }

        guard let vDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            fail("无法创建竖屏虚拟显示器")
            return
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = preferHiDPI ? 1 : 0
        settings.rotation = 0
        settings.modes = presets.map { preset in
            CGVirtualDisplayMode(
                width: UInt32(preset.size.width),
                height: UInt32(preset.size.height),
                refreshRate: metrics.refreshRate
            )
        }

        guard vDisplay.applySettings(settings) else {
            fail("应用竖屏虚拟显示器配置失败")
            return
        }

        self.virtualDisplay = vDisplay
        updateStatus("正在激活 HiDPI 模式与排列…")

        let readyCheck: () -> Bool = {
            let hasScreen = NSScreen.screens.contains { SidecarBridge.displayID(of: $0) == vDisplay.displayID }
            let hasMode = Self.findDisplayMode(for: vDisplay.displayID, logicalSize: portraitSize, preferHiDPI: preferHiDPI) != nil
            return hasScreen && hasMode
        }

        waitUntil(readyCheck, tries: 40, interval: 0.15) { [weak self] appeared in
            guard let self else { return }
            guard appeared, let latestMetrics = self.currentMetrics() else {
                self.fail("竖屏虚拟显示器未就绪")
                return
            }

            if let hiDPIMode = Self.findDisplayMode(
                for: vDisplay.displayID,
                logicalSize: portraitSize,
                preferHiDPI: preferHiDPI
            ) {
                Self.applyDisplayMode(hiDPIMode, on: vDisplay.displayID)
            }

            let actualSize = CGDisplayCopyDisplayMode(vDisplay.displayID).map {
                CGSize(width: $0.width, height: $0.height)
            } ?? portraitSize

            let moves = latestMetrics.computeDisplayOrigins(
                mainBounds: CGDisplayBounds(CGMainDisplayID()),
                virtualID: vDisplay.displayID,
                portraitSize: actualSize,
                placeOnLeft: self.placeOnLeft
            )
            Self.applyDisplayOrigins(moves)
            self.refreshGeometryCache(sidecarID: latestMetrics.displayID)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.startScreenCapture(virtualID: vDisplay.displayID, metrics: latestMetrics, portraitSize: actualSize)
            }
        }
    }

    private func startScreenCapture(virtualID: CGDirectDisplayID, metrics: SidecarMetrics, portraitSize: CGSize) {
        if !CGPreflightScreenCaptureAccess() {
            transitionState = .idle
            shouldBeVertical = false
            teardown()
            requestScreenCapturePermission()
            return
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] shareable, err in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.shouldBeVertical else { return }
                guard let scDisplay = shareable?.displays.first(where: { $0.displayID == virtualID }) else {
                    if let err {
                        self.fail("录屏捕获失败：\(err.localizedDescription)")
                    } else {
                        self.fail("未找到竖屏虚拟显示器")
                    }
                    return
                }

                let cfg = SCStreamConfiguration()
                cfg.width = Int(metrics.portraitCapturePixels.width)
                cfg.height = Int(metrics.portraitCapturePixels.height)
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(Int(metrics.refreshRate.rounded()), 30)))
                cfg.showsCursor = true
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.queueDepth = 3
                if #available(macOS 14.0, *) {
                    cfg.colorSpaceName = CGColorSpace.displayP3
                }
                #if compiler(>=6.0)
                if #available(macOS 15.0, *) {
                    cfg.captureResolution = .best
                }
                #endif

                let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
                let newStream = SCStream(filter: filter, configuration: cfg, delegate: self)
                do {
                    try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                } catch {
                    self.fail("添加采集输出失败：\(error.localizedDescription)")
                    return
                }

                newStream.startCapture { [weak self] err in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let err {
                            self.fail("开启画面采集失败：\(err.localizedDescription)")
                            return
                        }
                        self.stream = newStream
                        self.refreshGeometryCache(sidecarID: metrics.displayID)
                        let touchReady = self.activateTouchRemapper()
                        self.showOverlayWindow()
                        self.overlayWindow?.ignoresMouseEvents = !touchReady
                        if self.cursorGuardEnabled && !touchReady {
                            self.installCursorGuard()
                        } else {
                            self.removeCursorGuard()
                        }
                        self.transitionState = .idle
                        let active = CGDisplayCopyDisplayMode(virtualID)
                        let pW = active?.width ?? Int(portraitSize.width)
                        let pH = active?.height ?? Int(portraitSize.height)
                        let hiDPI = (active.map { $0.pixelWidth > $0.width } ?? false) ? "HiDPI 2x" : "1x"
                        if touchReady {
                            self.updateStatus("竖屏 \(pW)×\(pH) \(hiDPI) @ \(Int(metrics.refreshRate))Hz · Ctrl+Opt+V")
                        } else {
                            self.updateStatus("竖屏 \(pW)×\(pH) \(hiDPI) · 触控需「辅助功能」授权")
                        }
                    }
                }
            }
        }
    }

    private func showOverlayWindow() {
        guard let screen = SidecarBridge.findSidecarScreen(excludingVirtualID: virtualDisplay?.displayID ?? 0) else {
            fail("随航显示器已断开")
            return
        }

        let window = SidecarOverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isFloatingPanel = false
        // Must stay above Menubar (layer 24) / status items (layer 25) on the hidden Sidecar display.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = !touchRemapper.isRunning
        window.becomesKeyOnlyIfNeeded = true
        window.acceptsMouseMovedEvents = true
        window.hasShadow = false
        window.canHide = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.displaysWhenScreenProfileChanges = false
        window.isReleasedWhenClosed = false

        let recognizer = SidecarDirectTouchRecognizer(geometryProvider: { [weak self] in
            self?.touchRemapper.geometrySnapshot() ?? SidecarTouchRemapper.Geometry()
        })
        let view = SidecarOverlayInputView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            recognizer: recognizer
        )
        view.allowedTouchTypes = [.direct]

        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        rootLayer.contentsScale = screen.backingScaleFactor
        view.layer = rootLayer
        view.wantsLayer = true

        contentLayer.contentsGravity = .resize
        contentLayer.contentsScale = screen.backingScaleFactor
        contentLayer.isOpaque = true
        contentLayer.magnificationFilter = .linear
        contentLayer.minificationFilter = .linear
        contentLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "transform": NSNull(),
        ]
        rootLayer.addSublayer(contentLayer)

        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        overlayWindow = window
        layoutContentLayer()

        if #available(macOS 27.0, *) {
            SidecarTouchRemapper.logOverlaySetup(
                ignoresMouse: window.ignoresMouseEvents,
                touchCapabilitiesRaw: screen.touchCapabilities.rawValue
            )
        } else {
            SidecarTouchRemapper.logOverlaySetup(
                ignoresMouse: window.ignoresMouseEvents,
                touchCapabilitiesRaw: 0
            )
        }
    }

    private func layoutContentLayer() {
        guard let size = overlayWindow?.contentView?.bounds.size else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.bounds = CGRect(x: 0, y: 0, width: size.height, height: size.width)
        contentLayer.position = CGPoint(x: size.width / 2.0, y: size.height / 2.0)
        let angle: CGFloat = (rotationDegrees == 270) ? (.pi / 2.0) : (-.pi / 2.0)
        contentLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
    }

    // MARK: - SCStreamOutput & SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.contentLayer.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shouldBeVertical else { return }
            self.scheduleRecovery(reason: "采集流中断（\(error.localizedDescription)），正在恢复…")
        }
    }

    // MARK: - Event-Driven Zero-Polling Cursor Guard

    private func installCursorGuard() {
        removeCursorGuard()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            self?.enforceCursorGuard()
        }
    }

    private func removeCursorGuard() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        lastSafeCursorLocation = nil
    }

    private func enforceCursorGuard() {
        guard isVertical, !touchRemapper.isRunning, !cachedHiddenBounds.isNull, cachedMainHeight > 0 else { return }

        let nsLoc = NSEvent.mouseLocation
        let current = CGPoint(x: nsLoc.x, y: cachedMainHeight - nsLoc.y)
        if !cachedHiddenBounds.contains(current) {
            lastSafeCursorLocation = current
            return
        }
        if let safe = lastSafeCursorLocation {
            CGWarpMouseCursorPosition(safe)
        }
    }

    private func refreshGeometryCache(sidecarID: CGDirectDisplayID) {
        cachedMainHeight = CGDisplayBounds(CGMainDisplayID()).height
        cachedHiddenBounds = CGDisplayBounds(sidecarID)
        cachedVirtualBounds = virtualDisplay.map { CGDisplayBounds($0.displayID) } ?? .null
        pushTouchGeometry()
    }

    private func pushTouchGeometry() {
        touchRemapper.updateGeometry(
            hiddenBounds: cachedHiddenBounds,
            virtualBounds: cachedVirtualBounds,
            rotationDegrees: rotationDegrees,
            isActive: isVertical
        )
    }

    @discardableResult
    private func activateTouchRemapper() -> Bool {
        pushTouchGeometry()
        if touchRemapper.start() {
            stopAccessibilityWatcher()
            removeCursorGuard()
            return true
        }
        if !AXIsProcessTrusted(), !UserDefaults.standard.bool(forKey: Keys.accessibilityPrompted) {
            UserDefaults.standard.set(true, forKey: Keys.accessibilityPrompted)
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        startAccessibilityWatcherIfNeeded()
        return false
    }

    private func startAccessibilityWatcherIfNeeded() {
        guard accessibilityWatchTimer == nil, isVertical else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            guard let self, self.isVertical else {
                self?.stopAccessibilityWatcher()
                return
            }
            if AXIsProcessTrusted() {
                self.syncTouchRemapperIfNeeded()
            }
        }
        accessibilityWatchTimer = timer
        timer.resume()
    }

    private func stopAccessibilityWatcher() {
        accessibilityWatchTimer?.cancel()
        accessibilityWatchTimer = nil
    }

    // MARK: - Global Hotkey (Ctrl+Option+V)

    private func syncGlobalHotKey() {
        if hotkeyEnabled {
            registerGlobalHotKey()
        } else {
            unregisterGlobalHotKey()
        }
    }

    private func registerGlobalHotKey() {
        Self.hotKeyTarget = self
        if !hotKeyHandlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async {
                    SidecarController.hotKeyTarget?.toggle()
                }
                return noErr
            }, 1, &spec, nil, nil)
            hotKeyHandlerInstalled = true
        }
        if hotKeyRef == nil {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D50_5456), id: 1) // 'MPTV'
            RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
            hotKeyRef = ref
        }
    }

    private func unregisterGlobalHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    // MARK: - System Lifecycle Recovery

    private func registerSystemObserversIfNeeded() {
        guard !systemObserversRegistered else { return }
        systemObserversRegistered = true

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(handleWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDidWake),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    @objc private func handleWillSleep() {
        guard shouldBeVertical else { return }
        teardown()
        updateStatus("系统休眠/锁屏，等待唤醒恢复…")
    }

    @objc private func handleDidWake() {
        guard shouldBeVertical, !isVertical, !isStarting else { return }
        scheduleRecovery(reason: "系统唤醒，正在重建竖屏随航…", delay: 1.5)
    }

    @objc private func handleAppDidBecomeActive() {
        syncTouchRemapperIfNeeded()
    }

    @objc private func handleScreenChange() {
        if !isVertical && !isStarting {
            notifyStateChanged()
            return
        }
        guard isVertical, let metrics = currentMetrics(), let old = lastMetrics else { return }
        if metrics.landscapePixels != old.landscapePixels || metrics.displayID != old.displayID {
            scheduleRecovery(reason: "随航分辨率已变化，正在自适应重建…", delay: 0.8)
            return
        }
        if let screen = SidecarBridge.findSidecarScreen(excludingVirtualID: virtualDisplay?.displayID ?? 0),
           let win = overlayWindow, win.frame != screen.frame {
            win.setFrame(screen.frame, display: true)
            layoutContentLayer()
        }
        refreshGeometryCache(sidecarID: metrics.displayID)
        syncTouchRemapperIfNeeded()
        notifyStateChanged()
    }

    private func scheduleRecovery(reason: String, delay: TimeInterval = 1.0) {
        recoveryTask?.cancel()
        updateStatus(reason)
        teardown()
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.shouldBeVertical else { return }
            self.enableVertical()
        }
        recoveryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    // MARK: - Helpers

    private func ensureSidecarConnected(_ completion: @escaping (Bool) -> Void) {
        if currentMetrics() != nil {
            completion(true)
            return
        }
        guard !SidecarBridge.devices().isEmpty else {
            completion(false)
            return
        }
        SidecarBridge.connect { [weak self] initiated in
            guard let self else { return }
            let retries = initiated ? 20 : 2
            self.waitUntil({ self.currentMetrics() != nil }, tries: retries, completion: completion)
        }
    }

    private func waitUntil(
        _ condition: @escaping () -> Bool,
        tries: Int,
        interval: TimeInterval = 0.5,
        completion: @escaping (Bool) -> Void
    ) {
        if condition() {
            completion(true)
            return
        }
        if tries <= 0 {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            self.waitUntil(condition, tries: tries - 1, interval: interval, completion: completion)
        }
    }

    private func fail(_ message: String) {
        fputs("MacPowerTemp SidecarVertical error: \(message)\n", stderr)
        shouldBeVertical = false
        transitionState = .idle
        teardown()
        updateStatus(message)
    }

    func teardown() {
        stopAccessibilityWatcher()
        touchRemapper.stop()
        removeCursorGuard()
        cachedHiddenBounds = .null
        cachedVirtualBounds = .null
        cachedMainHeight = 0
        let activeStream = stream
        stream = nil
        activeStream?.stopCapture(completionHandler: nil)
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        contentLayer.contents = nil
        contentLayer.removeFromSuperlayer()
        virtualDisplay = nil
    }

    private func restoreHorizontalOrigin(for metrics: SidecarMetrics) {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let x = placeOnLeft
            ? Int32(mainBounds.minX) - Int32(metrics.landscapePoints.width)
            : Int32(mainBounds.maxX)
        Self.applyDisplayOrigins([(metrics.displayID, x, Int32(mainBounds.minY))])
    }

    private func updateStatus(_ text: String) {
        statusText = text
        notifyStateChanged()
    }

    private func notifyStateChanged() {
        onStateChanged?()
    }

    static func findDisplayMode(
        for displayID: CGDirectDisplayID,
        logicalSize: CGSize,
        preferHiDPI: Bool
    ) -> CGDisplayMode? {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else {
            return nil
        }
        let targetW = Int(logicalSize.width.rounded())
        let targetH = Int(logicalSize.height.rounded())
        let matches = modes.filter {
            $0.width == targetW && $0.height == targetH && $0.isUsableForDesktopGUI()
        }
        guard !matches.isEmpty else { return nil }
        return preferHiDPI
            ? matches.max(by: { $0.pixelWidth < $1.pixelWidth })
            : matches.min(by: { $0.pixelWidth < $1.pixelWidth })
    }

    @discardableResult
    private static func applyDisplayMode(_ mode: CGDisplayMode, on displayID: CGDirectDisplayID) -> Bool {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(cfg, displayID, mode, nil)
        return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
    }

    private static func applyDisplayOrigins(_ moves: [(CGDirectDisplayID, Int32, Int32)]) {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        for (id, x, y) in moves {
            CGConfigureDisplayOrigin(cfg, id, x, y)
        }
        CGCompleteDisplayConfiguration(cfg, .forSession)
    }
}

/// Intercepts Sidecar touch, Apple Pencil, pointer, and scroll events targeting the hidden
/// landscape Sidecar display at the HID entry point and remaps them onto the rotated portrait
/// virtual display before WindowServer cursor placement and window hit-testing.
private final class SidecarTouchRemapper {
    struct Geometry {
        var hiddenBounds: CGRect = .null
        var virtualBounds: CGRect = .null
        var rotationDegrees: Int = 270
        var isActive: Bool = false
    }

    private let lock = NSLock()
    private var geometry = Geometry()
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var running = false
    private var loggedRemapCount = 0
    private var loggedFirstCallback = false

    static let logger = Logger(subsystem: "com.workbuddy.macpowertemp", category: "sidecar")
    private static let remappedUserDataMagic: Int64 = 0x4D50_5454 // 'MPTT'

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && machPort != nil
    }

    func geometrySnapshot() -> Geometry {
        lock.lock()
        defer { lock.unlock() }
        return geometry
    }

    static func logOverlaySetup(ignoresMouse: Bool, touchCapabilitiesRaw: UInt) {
        logger.notice("Overlay panel ready: ignoresMouse=\(ignoresMouse, privacy: .public) touchCapabilities=\(touchCapabilitiesRaw, privacy: .public)")
    }

    static func clearHitTestFields(on event: CGEvent) {
        for rawField in [39, 40, 91, 92] {
            if let field = CGEventField(rawValue: UInt32(rawField)) {
                event.setIntegerValueField(field, value: 0)
            }
        }
    }

    static func postSyntheticMouseEvent(
        source: CGEventSource?,
        type: CGEventType,
        button: CGMouseButton,
        location: CGPoint,
        clickState: Int64 = 1,
        deltaX: Int64 = 0,
        deltaY: Int64 = 0
    ) {
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button) else {
            return
        }
        ev.setIntegerValueField(.eventSourceUserData, value: remappedUserDataMagic)
        if type != .mouseMoved {
            ev.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        if deltaX != 0 || deltaY != 0 {
            ev.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
            ev.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
        }
        clearHitTestFields(on: ev)
        ev.post(tap: .cghidEventTap)
    }

    enum GestureKind: Int64 {
        case rotate = 5
        case zoom = 8
    }

    static func postSyntheticScrollEvent(
        source: CGEventSource?,
        location: CGPoint,
        axis1: Int32,
        axis2: Int32,
        scrollPhase: CGScrollPhase? = nil,
        momentumPhase: CGMomentumScrollPhase = .none
    ) {
        guard let ev = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: axis1,
            wheel2: axis2,
            wheel3: 0
        ) else {
            return
        }
        ev.location = location
        ev.setIntegerValueField(.eventSourceUserData, value: remappedUserDataMagic)
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if let scrollPhase {
            ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(scrollPhase.rawValue))
        }
        if momentumPhase != .none {
            ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentumPhase.rawValue))
        }
        clearHitTestFields(on: ev)
        ev.post(tap: .cghidEventTap)
    }

    static func postSyntheticGestureEvent(
        source: CGEventSource?,
        kind: GestureKind,
        phase: CGGesturePhase,
        location: CGPoint,
        value: Double
    ) {
        guard let ev = CGEvent(source: source),
              let gestureType = CGEventType(rawValue: 29) else {
            return
        }
        ev.type = gestureType
        ev.location = location
        ev.setIntegerValueField(.eventSourceUserData, value: remappedUserDataMagic)
        if let fKind = CGEventField(rawValue: 110) {
            ev.setIntegerValueField(fKind, value: kind.rawValue)
        }
        if let fPhase = CGEventField(rawValue: 132) {
            ev.setIntegerValueField(fPhase, value: Int64(phase.rawValue))
        }
        if let fValue = CGEventField(rawValue: 113) {
            ev.setDoubleValueField(fValue, value: value)
        }
        clearHitTestFields(on: ev)
        ev.post(tap: .cghidEventTap)
    }

    private static let eventMask: CGEventMask = {
        let rawTypes: [UInt32] = [
            CGEventType.leftMouseDown.rawValue,
            CGEventType.leftMouseUp.rawValue,
            CGEventType.rightMouseDown.rawValue,
            CGEventType.rightMouseUp.rawValue,
            CGEventType.mouseMoved.rawValue,
            CGEventType.leftMouseDragged.rawValue,
            CGEventType.rightMouseDragged.rawValue,
            CGEventType.scrollWheel.rawValue,
            CGEventType.tabletPointer.rawValue,
            CGEventType.tabletProximity.rawValue,
            CGEventType.otherMouseDown.rawValue,
            CGEventType.otherMouseUp.rawValue,
            CGEventType.otherMouseDragged.rawValue,
            18, // NSEventTypeRotate
            19, // NSEventTypeBeginGesture
            20, // NSEventTypeEndGesture
            29, // NSEventTypeGesture
            30, // NSEventTypeMagnify
            31, // NSEventTypeSwipe
            32, // NSEventTypeSmartMagnify
            33, // NSEventTypeQuickLook
            34, // NSEventTypePressure
            37, // NSEventTypeDirectTouch
            40, // NSEventTypeMouseCancelled
        ]
        return rawTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }
    }()

    deinit {
        stop()
    }

    func updateGeometry(hiddenBounds: CGRect, virtualBounds: CGRect, rotationDegrees: Int, isActive: Bool) {
        lock.lock()
        let becameActive = isActive && !geometry.isActive
        geometry = Geometry(
            hiddenBounds: hiddenBounds,
            virtualBounds: virtualBounds,
            rotationDegrees: rotationDegrees,
            isActive: isActive
        )
        lock.unlock()
        if becameActive {
            Self.logger.notice("Geometry active: hidden=\(NSStringFromRect(hiddenBounds), privacy: .public) virtual=\(NSStringFromRect(virtualBounds), privacy: .public) rot=\(rotationDegrees, privacy: .public)")
        }
    }

    @discardableResult
    func start() -> Bool {
        lock.lock()
        if running && machPort != nil {
            lock.unlock()
            return true
        }
        lock.unlock()

        let trusted = AXIsProcessTrusted()
        let postOK = CGPreflightPostEventAccess()
        let listenOK = CGPreflightListenEventAccess()
        Self.logger.notice("Starting touch remapper: AX=\(trusted, privacy: .public) Post=\(postOK, privacy: .public) Listen=\(listenOK, privacy: .public)")
        guard trusted else { return false }

        let readySem = DispatchSemaphore(value: 0)
        var created = false

        let thread = Thread { [weak self] in
            guard let self else {
                readySem.signal()
                return
            }
            let userInfo = Unmanaged.passUnretained(self).toOpaque()
            let callback: CGEventTapCallBack = { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let remapper = Unmanaged<SidecarTouchRemapper>.fromOpaque(refcon).takeUnretainedValue()
                return remapper.handleEvent(proxy: proxy, type: type, event: event)
            }

            // User-space apps should use .cgSessionEventTap (requires Accessibility); fall back to .cghidEventTap.
            let sessionPort = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.eventMask,
                callback: callback,
                userInfo: userInfo
            )
            let tapSourceName = sessionPort != nil ? "cgSessionEventTap" : "cghidEventTap"
            guard let port = sessionPort ?? CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.eventMask,
                callback: callback,
                userInfo: userInfo
            ) else {
                Self.logger.error("CGEvent.tapCreate failed for both cgSessionEventTap and cghidEventTap")
                readySem.signal()
                return
            }
            Self.logger.notice("Touch remapper tap created via \(tapSourceName, privacy: .public)")

            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                CFMachPortInvalidate(port)
                readySem.signal()
                return
            }

            let rl = CFRunLoopGetCurrent()
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)

            self.lock.lock()
            self.machPort = port
            self.runLoopSource = source
            self.tapRunLoop = rl
            self.running = true
            self.loggedRemapCount = 0
            self.lock.unlock()

            created = true
            readySem.signal()

            CFRunLoopRun()

            self.lock.lock()
            if self.machPort === port {
                self.machPort = nil
                self.runLoopSource = nil
                self.tapRunLoop = nil
                self.running = false
            }
            self.lock.unlock()
        }
        thread.name = "com.workbuddy.macpowertemp.sidecar.touchtap"
        thread.qualityOfService = .userInteractive
        thread.start()

        _ = readySem.wait(timeout: .now() + 1.0)
        return created
    }

    func stop() {
        lock.lock()
        geometry.isActive = false
        let port = machPort
        let source = runLoopSource
        let rl = tapRunLoop
        machPort = nil
        runLoopSource = nil
        tapRunLoop = nil
        running = false
        lock.unlock()

        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let rl, let source {
            CFRunLoopRemoveSource(rl, source, .commonModes)
        }
        if let rl {
            CFRunLoopStop(rl)
        }
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let port = machPort
            lock.unlock()
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.remappedUserDataMagic {
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let firstCB = !loggedFirstCallback
        if firstCB { loggedFirstCallback = true }
        let geo = geometry
        lock.unlock()

        let loc = event.location
        if firstCB {
            Self.logger.notice("CGEventTap first callback: type=\(type.rawValue, privacy: .public) loc=(\(loc.x, privacy: .public),\(loc.y, privacy: .public))")
        }

        guard geo.isActive, !geo.hiddenBounds.isNull, !geo.virtualBounds.isNull else {
            return Unmanaged.passUnretained(event)
        }

        guard geo.hiddenBounds.contains(loc) else {
            return Unmanaged.passUnretained(event)
        }

        let mapped = SidecarInputTransform.mapPoint(
            loc,
            from: geo.hiddenBounds,
            to: geo.virtualBounds,
            rotationDegrees: geo.rotationDegrees
        )

        lock.lock()
        let shouldLog = loggedRemapCount < 8
        if shouldLog { loggedRemapCount += 1 }
        lock.unlock()
        if shouldLog {
            Self.logger.notice("Remap type=\(type.rawValue, privacy: .public) (\(loc.x, privacy: .public),\(loc.y, privacy: .public)) -> (\(mapped.x, privacy: .public),\(mapped.y, privacy: .public))")
        }

        if Self.shouldRepost(type: type), let copy = event.copy() {
            copy.location = mapped
            copy.setIntegerValueField(.eventSourceUserData, value: Self.remappedUserDataMagic)
            // Clear WindowServer's pre-tap hit-test target so posting at HID level re-targets virtualDisplay.
            Self.clearHitTestFields(on: copy)

            Self.applyRotationTransforms(to: copy, type: type, geometry: geo)
            copy.post(tap: .cghidEventTap)
            return nil
        }

        event.location = mapped
        Self.applyRotationTransforms(to: event, type: type, geometry: geo)
        return Unmanaged.passUnretained(event)
    }

    private static func applyRotationTransforms(to event: CGEvent, type: CGEventType, geometry: Geometry) {
        if type == .scrollWheel {
            rotateScrollFields(on: event, rotationDegrees: geometry.rotationDegrees)
        } else {
            rotateMouseDeltasIfNeeded(
                on: event,
                from: geometry.hiddenBounds,
                to: geometry.virtualBounds,
                rotationDegrees: geometry.rotationDegrees
            )
            rotateTabletTiltIfNeeded(on: event, type: type, rotationDegrees: geometry.rotationDegrees)
        }
    }

    private static func shouldRepost(type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .mouseMoved, .scrollWheel, .tabletPointer, .tabletProximity:
            return true
        default:
            return false
        }
    }

    private static func rotateMouseDeltasIfNeeded(
        on event: CGEvent,
        from hiddenBounds: CGRect,
        to virtualBounds: CGRect,
        rotationDegrees: Int
    ) {
        let sx = Double(virtualBounds.width / max(hiddenBounds.height, 1.0))
        let sy = Double(virtualBounds.height / max(hiddenBounds.width, 1.0))

        let dx = event.getIntegerValueField(.mouseEventDeltaX)
        let dy = event.getIntegerValueField(.mouseEventDeltaY)
        if dx != 0 || dy != 0 {
            let (rx, ry) = SidecarInputTransform.rotateVector(Double(dx), Double(dy), rotationDegrees: rotationDegrees)
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64((rx * sx).rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64((ry * sy).rounded()))
        }

        if let fX = CGEventField(rawValue: 170), let fY = CGEventField(rawValue: 171) {
            let ux = event.getDoubleValueField(fX)
            let uy = event.getDoubleValueField(fY)
            if ux != 0 || uy != 0 {
                let (rx, ry) = SidecarInputTransform.rotateVector(ux, uy, rotationDegrees: rotationDegrees)
                event.setDoubleValueField(fX, value: rx * sx)
                event.setDoubleValueField(fY, value: ry * sy)
            }
        }
    }

    private static func rotateTabletTiltIfNeeded(on event: CGEvent, type: CGEventType, rotationDegrees: Int) {
        let isTablet = type == .tabletPointer
            || event.getIntegerValueField(.mouseEventSubtype) == Int64(CGEventMouseSubtype.tabletPoint.rawValue)
        guard isTablet else { return }

        let tx = event.getDoubleValueField(.tabletEventTiltX)
        let ty = event.getDoubleValueField(.tabletEventTiltY)
        guard tx != 0 || ty != 0 else { return }

        // AppKit/tablet tilt uses +Y up, matching CALayer rotation (+pi/2 for 270°, -pi/2 for 90°).
        let (rx, ry) = rotationDegrees == 270 ? (-ty, tx) : (ty, -tx)
        event.setDoubleValueField(.tabletEventTiltX, value: rx)
        event.setDoubleValueField(.tabletEventTiltY, value: ry)
    }

    private static func rotateScrollFields(on event: CGEvent, rotationDegrees: Int) {
        let intPairs: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2),
            (.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2),
        ]
        for (f1, f2) in intPairs {
            let a1 = event.getIntegerValueField(f1)
            let a2 = event.getIntegerValueField(f2)
            if a1 != 0 || a2 != 0 {
                let r = SidecarInputTransform.rotateScrollAxesInt(axis1: a1, axis2: a2, rotationDegrees: rotationDegrees)
                event.setIntegerValueField(f1, value: r.axis1)
                event.setIntegerValueField(f2, value: r.axis2)
            }
        }

        var doublePairs: [(CGEventField, CGEventField)] = [
            (.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2),
        ]
        if let a1 = CGEventField(rawValue: 176), let a2 = CGEventField(rawValue: 175) {
            doublePairs.append((a1, a2))
        }
        if let r1 = CGEventField(rawValue: 178), let r2 = CGEventField(rawValue: 177) {
            doublePairs.append((r1, r2))
        }
        for (f1, f2) in doublePairs {
            let v1 = event.getDoubleValueField(f1)
            let v2 = event.getDoubleValueField(f2)
            if v1 != 0 || v2 != 0 {
                let r = SidecarInputTransform.rotateScrollAxes(axis1: v1, axis2: v2, rotationDegrees: rotationDegrees)
                event.setDoubleValueField(f1, value: r.axis1)
                event.setDoubleValueField(f2, value: r.axis2)
            }
        }
    }
}

/// Non-activating borderless overlay panel over the hidden landscape Sidecar display.
/// Prevents macOS 27 Direct Touch hits from leaking onto the hidden Desktop wallpaper while never stealing focus.
private final class SidecarOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

private final class SidecarOverlayInputView: NSView {
    private let touchRecognizer: SidecarDirectTouchRecognizer

    init(frame: NSRect, recognizer: SidecarDirectTouchRecognizer) {
        self.touchRecognizer = recognizer
        super.init(frame: frame)
        addGestureRecognizer(recognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        if !touchRecognizer.handleOverlayScrollWheel(event) {
            super.scrollWheel(with: event)
        }
    }
}

/// Captures macOS 27 Sidecar Direct Touch (and fallback mouse/tablet events hitting the hidden overlay)
/// and translates them into natural touchscreen interactions on the rotated virtual display:
/// single/double tap, 1-finger touch scroll (or hold/control drag), two-finger pinch-to-zoom,
/// two-finger rotation, two-finger inertial scroll, and two-finger right-click.
private final class SidecarDirectTouchRecognizer: NSGestureRecognizer {
    private enum TwoFingerSubMode {
        case undecided
        case scrolling
        case pinching
    }

    private enum Mode: Equatable {
        case idle
        case pendingOneFinger(identity: NSObject, startViewPt: NSPoint, startTime: TimeInterval, preferImmediateDrag: Bool)
        case scrollingOneFinger(identity: NSObject, anchorVirtualPt: CGPoint, lastVirtualPt: CGPoint, lastTimestamp: TimeInterval)
        case draggingOneFinger(identity: NSObject, lastVirtualPt: CGPoint, clickState: Int64)
        case twoFinger(
            idA: NSObject,
            idB: NSObject,
            anchorVirtualPt: CGPoint,
            initialCentroidVirtual: CGPoint,
            lastCentroidVirtual: CGPoint,
            initialSpan: CGFloat,
            lastSpan: CGFloat,
            initialAngleRad: CGFloat,
            lastAngleRad: CGFloat,
            startTime: TimeInterval,
            lastTimestamp: TimeInterval,
            subMode: TwoFingerSubMode,
            rotateBegan: Bool
        )

        static func == (lhs: Mode, rhs: Mode) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle):
                return true
            case let (.pendingOneFinger(a, _, _, _), .pendingOneFinger(b, _, _, _)):
                return a.isEqual(b)
            case let (.scrollingOneFinger(a, _, _, _), .scrollingOneFinger(b, _, _, _)):
                return a.isEqual(b)
            case let (.draggingOneFinger(a, _, _), .draggingOneFinger(b, _, _)):
                return a.isEqual(b)
            case (.twoFinger, .twoFinger):
                return true
            default:
                return false
            }
        }
    }

    private static let dragPriorityRoles: Set<String> = [
        kAXSliderRole as String,
        kAXScrollBarRole as String,
        kAXValueIndicatorRole as String,
        kAXSplitterRole as String,
        "AXTitleBar",
        "AXHandle",
        kAXButtonRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String,
        kAXMenuItemRole as String,
        kAXMenuButtonRole as String,
    ]

    private let geometryProvider: () -> SidecarTouchRemapper.Geometry
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let systemWideAX: AXUIElement = {
        let el = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(el, 0.015)
        return el
    }()

    private var lastLocationInOwnView: NSPoint = .zero
    private var activeTouches: [(identity: NSObject, point: NSPoint)] = []
    private var mode: Mode = .idle
    private var pendingDragWorkItem: DispatchWorkItem?
    private var lastClickUptime: TimeInterval = 0
    private var lastClickVirtualPt: CGPoint = .zero
    private var clickSequenceCount: Int64 = 1
    private var lastDirectTouchTimestamp: TimeInterval = -1

    private var scrollRemainderX: Double = 0
    private var scrollRemainderY: Double = 0
    private var scrollVelocityX: Double = 0
    private var scrollVelocityY: Double = 0
    private var lastScrollSampleTime: TimeInterval = -1
    private var momentumTimer: DispatchSourceTimer?
    private var momentumAnchorPt: CGPoint = .zero
    private var momentumStarted = false

    private var activeFallbackButton: CGMouseButton?
    private var lastFallbackVirtualPt: CGPoint = .zero
    private var loggedTouchCount = 0

    init(geometryProvider: @escaping () -> SidecarTouchRemapper.Geometry) {
        self.geometryProvider = geometryProvider
        super.init(target: nil, action: nil)
        allowedTouchTypes = [.direct]
        delaysPrimaryMouseButtonEvents = false
        delaysSecondaryMouseButtonEvents = false
        delaysOtherMouseButtonEvents = false
        if #available(macOS 27.0, *) {
            isCancellableByScrollGesture = false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        cancelPendingDragTimer()
        stopMomentum(emitEnd: false)
    }

    override func location(in view: NSView?) -> NSPoint {
        guard let ownView = self.view else { return .zero }
        guard let targetView = view else {
            return ownView.convert(lastLocationInOwnView, to: nil)
        }
        if targetView === ownView {
            return lastLocationInOwnView
        }
        return ownView.convert(lastLocationInOwnView, to: targetView)
    }

    override func reset() {
        cancelPendingDragTimer()
        activeTouches.removeAll()
        mode = .idle
        resetScrollKinematics()
        super.reset()
    }

    // MARK: - Direct Touch Lifecycle

    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        lastDirectTouchTimestamp = event.timestamp
        stopMomentum(emitEnd: true)
        _ = syncTouches(from: event)
        guard !activeTouches.isEmpty else { return }

        switch mode {
        case .idle:
            if activeTouches.count == 1, let first = activeTouches.first {
                lastLocationInOwnView = first.point
                let immediateDrag = mapViewPoint(first.point).map { shouldOneFingerMoveImmediatelyDrag(at: $0) } ?? false
                mode = .pendingOneFinger(
                    identity: first.identity,
                    startViewPt: first.point,
                    startTime: event.timestamp,
                    preferImmediateDrag: immediateDrag
                )
                schedulePendingDragTimer(delay: immediateDrag ? 0.045 : 0.22)
                state = .possible
                logTouchEvent(action: "began1(drag=\(immediateDrag))", viewPt: first.point)
            } else {
                startTwoFingerMode(timestamp: event.timestamp)
            }
        case .pendingOneFinger:
            if activeTouches.count >= 2 {
                cancelPendingDragTimer()
                startTwoFingerMode(timestamp: event.timestamp)
            }
        case .scrollingOneFinger(_, let anchorPt, _, _):
            if activeTouches.count >= 2 {
                SidecarTouchRemapper.postSyntheticScrollEvent(
                    source: eventSource,
                    location: anchorPt,
                    axis1: 0,
                    axis2: 0,
                    scrollPhase: .ended
                )
                startTwoFingerMode(timestamp: event.timestamp)
            }
        case .draggingOneFinger, .twoFinger:
            break
        }
    }

    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        lastDirectTouchTimestamp = event.timestamp
        _ = syncTouches(from: event)

        switch mode {
        case .idle:
            break
        case let .pendingOneFinger(identity, startViewPt, startTime, preferImmediateDrag):
            if activeTouches.count >= 2 {
                cancelPendingDragTimer()
                startTwoFingerMode(timestamp: event.timestamp)
                return
            }
            guard let pt = pointForTouch(identity: identity) else { return }
            lastLocationInOwnView = pt
            let dist = hypot(pt.x - startViewPt.x, pt.y - startViewPt.y)
            if preferImmediateDrag {
                if dist > 4.0 {
                    commitOneFingerDragIfPending(currentViewPt: pt)
                }
            } else if dist > 6.0 {
                // Quick 1-finger swipe on scrollable/general content becomes fluid touch scroll.
                cancelPendingDragTimer()
                if let vStart = mapViewPoint(startViewPt), let vCurr = mapViewPoint(pt) {
                    resetScrollKinematics()
                    SidecarTouchRemapper.postSyntheticScrollEvent(
                        source: eventSource,
                        location: vStart,
                        axis1: 0,
                        axis2: 0,
                        scrollPhase: .began
                    )
                    emitContinuousScrollStep(
                        anchor: vStart,
                        dx: Double(vCurr.x - vStart.x),
                        dy: Double(vCurr.y - vStart.y),
                        dt: max(event.timestamp - startTime, 0.016),
                        timestamp: event.timestamp,
                        phase: .changed
                    )
                    mode = .scrollingOneFinger(
                        identity: identity,
                        anchorVirtualPt: vStart,
                        lastVirtualPt: vCurr,
                        lastTimestamp: event.timestamp
                    )
                    state = .began
                    logTouchEvent(action: "scroll1Start", viewPt: pt, virtualPt: vCurr)
                }
            }

        case let .scrollingOneFinger(identity, anchorVirtualPt, lastVirtualPt, lastTimestamp):
            guard let pt = pointForTouch(identity: identity),
                  let vCurr = mapViewPoint(pt) else { return }
            lastLocationInOwnView = pt
            let dt = event.timestamp - lastTimestamp
            emitContinuousScrollStep(
                anchor: anchorVirtualPt,
                dx: Double(vCurr.x - lastVirtualPt.x),
                dy: Double(vCurr.y - lastVirtualPt.y),
                dt: dt,
                timestamp: event.timestamp,
                phase: .changed
            )
            mode = .scrollingOneFinger(
                identity: identity,
                anchorVirtualPt: anchorVirtualPt,
                lastVirtualPt: vCurr,
                lastTimestamp: event.timestamp
            )
            state = .changed

        case let .draggingOneFinger(identity, lastVirtualPt, clickState):
            guard let pt = pointForTouch(identity: identity),
                  let vPt = mapViewPoint(pt) else { return }
            lastLocationInOwnView = pt
            let dx = Int64((vPt.x - lastVirtualPt.x).rounded())
            let dy = Int64((vPt.y - lastVirtualPt.y).rounded())
            SidecarTouchRemapper.postSyntheticMouseEvent(
                source: eventSource,
                type: .leftMouseDragged,
                button: .left,
                location: vPt,
                clickState: clickState,
                deltaX: dx,
                deltaY: dy
            )
            mode = .draggingOneFinger(identity: identity, lastVirtualPt: vPt, clickState: clickState)
            state = .changed

        case let .twoFinger(
            idA, idB, anchorVirtualPt, initialCentroidVirtual, lastCentroidVirtual,
            initialSpan, lastSpan, initialAngleRad, lastAngleRad,
            startTime, lastTimestamp, subMode, rotateBegan
        ):
            guard let ptA = pointForTouch(identity: idA),
                  let ptB = pointForTouch(identity: idB),
                  let vpA = mapViewPoint(ptA),
                  let vpB = mapViewPoint(ptB) else { return }

            lastLocationInOwnView = NSPoint(x: (ptA.x + ptB.x) * 0.5, y: (ptA.y + ptB.y) * 0.5)
            let currCentroid = CGPoint(x: (vpA.x + vpB.x) * 0.5, y: (vpA.y + vpB.y) * 0.5)
            let currSpan = max(hypot(vpB.x - vpA.x, vpB.y - vpA.y), 1.0)
            let currAngle = atan2(vpB.y - vpA.y, vpB.x - vpA.x)

            var nextSubMode = subMode
            var nextRotateBegan = rotateBegan

            if nextSubMode == .undecided {
                let spanChange = abs(currSpan - initialSpan)
                let scaleFrac = spanChange / max(initialSpan, 50.0)
                let panDist = hypot(currCentroid.x - initialCentroidVirtual.x, currCentroid.y - initialCentroidVirtual.y)
                let totalRotDeg = abs(wrappedAngleDeltaDegrees(from: initialAngleRad, to: currAngle))

                if scaleFrac >= 0.05 || spanChange >= 12.0 || totalRotDeg >= 8.0 {
                    nextSubMode = .pinching
                    // Focus pointer at pinch midpoint so Photos/Preview/Safari zooms under fingers.
                    SidecarTouchRemapper.postSyntheticMouseEvent(
                        source: eventSource,
                        type: .mouseMoved,
                        button: .left,
                        location: anchorVirtualPt
                    )
                    SidecarTouchRemapper.postSyntheticGestureEvent(
                        source: eventSource,
                        kind: .zoom,
                        phase: .began,
                        location: anchorVirtualPt,
                        value: 0.0
                    )
                    logTouchEvent(action: "pinchBegan", viewPt: lastLocationInOwnView, virtualPt: anchorVirtualPt)
                } else if panDist >= 6.0 {
                    nextSubMode = .scrolling
                    resetScrollKinematics()
                    SidecarTouchRemapper.postSyntheticScrollEvent(
                        source: eventSource,
                        location: anchorVirtualPt,
                        axis1: 0,
                        axis2: 0,
                        scrollPhase: .began
                    )
                    logTouchEvent(action: "scroll2Began", viewPt: lastLocationInOwnView, virtualPt: anchorVirtualPt)
                }
            }

            if nextSubMode == .pinching {
                let magDelta = Double((currSpan / max(lastSpan, 1.0)) - 1.0)
                if abs(magDelta) > 0.0005 {
                    SidecarTouchRemapper.postSyntheticGestureEvent(
                        source: eventSource,
                        kind: .zoom,
                        phase: .changed,
                        location: anchorVirtualPt,
                        value: magDelta
                    )
                }
                let totalRotDeg = abs(wrappedAngleDeltaDegrees(from: initialAngleRad, to: currAngle))
                if !nextRotateBegan && totalRotDeg >= 8.0 {
                    nextRotateBegan = true
                    SidecarTouchRemapper.postSyntheticGestureEvent(
                        source: eventSource,
                        kind: .rotate,
                        phase: .began,
                        location: anchorVirtualPt,
                        value: 0.0
                    )
                }
                if nextRotateBegan {
                    let rotDelta = wrappedAngleDeltaDegrees(from: lastAngleRad, to: currAngle)
                    if abs(rotDelta) > 0.05 {
                        SidecarTouchRemapper.postSyntheticGestureEvent(
                            source: eventSource,
                            kind: .rotate,
                            phase: .changed,
                            location: anchorVirtualPt,
                            value: rotDelta
                        )
                    }
                }
            } else if nextSubMode == .scrolling {
                emitContinuousScrollStep(
                    anchor: anchorVirtualPt,
                    dx: Double(currCentroid.x - lastCentroidVirtual.x),
                    dy: Double(currCentroid.y - lastCentroidVirtual.y),
                    dt: event.timestamp - lastTimestamp,
                    timestamp: event.timestamp,
                    phase: .changed
                )
            }

            mode = .twoFinger(
                idA: idA,
                idB: idB,
                anchorVirtualPt: anchorVirtualPt,
                initialCentroidVirtual: initialCentroidVirtual,
                lastCentroidVirtual: currCentroid,
                initialSpan: initialSpan,
                lastSpan: currSpan,
                initialAngleRad: initialAngleRad,
                lastAngleRad: currAngle,
                startTime: startTime,
                lastTimestamp: event.timestamp,
                subMode: nextSubMode,
                rotateBegan: nextRotateBegan
            )
            state = .changed
        }
    }

    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event)
        lastDirectTouchTimestamp = event.timestamp
        let ended = syncTouches(from: event)

        switch mode {
        case .idle:
            break
        case let .pendingOneFinger(identity, startViewPt, _, _):
            let endedPt = ended.first(where: { $0.identity.isEqual(identity) })?.point
            if endedPt != nil || activeTouches.isEmpty {
                cancelPendingDragTimer()
                let tapViewPt = endedPt ?? startViewPt
                lastLocationInOwnView = tapViewPt
                if let vPt = mapViewPoint(tapViewPt) {
                    let clickCount = nextClickCount(at: vPt)
                    SidecarTouchRemapper.postSyntheticMouseEvent(
                        source: eventSource,
                        type: .mouseMoved,
                        button: .left,
                        location: vPt
                    )
                    SidecarTouchRemapper.postSyntheticMouseEvent(
                        source: eventSource,
                        type: .leftMouseDown,
                        button: .left,
                        location: vPt,
                        clickState: clickCount
                    )
                    SidecarTouchRemapper.postSyntheticMouseEvent(
                        source: eventSource,
                        type: .leftMouseUp,
                        button: .left,
                        location: vPt,
                        clickState: clickCount
                    )
                    logTouchEvent(action: "tap(\(clickCount))", viewPt: tapViewPt, virtualPt: vPt)
                }
                if activeTouches.isEmpty {
                    mode = .idle
                    state = .ended
                }
            }

        case let .scrollingOneFinger(identity, anchorVirtualPt, _, _):
            let endedMatch = ended.contains(where: { $0.identity.isEqual(identity) })
            if endedMatch || activeTouches.isEmpty {
                SidecarTouchRemapper.postSyntheticScrollEvent(
                    source: eventSource,
                    location: anchorVirtualPt,
                    axis1: 0,
                    axis2: 0,
                    scrollPhase: .ended
                )
                startMomentumIfFast(anchor: anchorVirtualPt, endTimestamp: event.timestamp)
                if activeTouches.isEmpty {
                    mode = .idle
                    state = .ended
                }
            }

        case let .draggingOneFinger(identity, lastVirtualPt, clickState):
            let endedPt = ended.first(where: { $0.identity.isEqual(identity) })?.point
            if endedPt != nil || activeTouches.isEmpty {
                let releasePt = endedPt.flatMap { mapViewPoint($0) } ?? lastVirtualPt
                SidecarTouchRemapper.postSyntheticMouseEvent(
                    source: eventSource,
                    type: .leftMouseUp,
                    button: .left,
                    location: releasePt,
                    clickState: clickState
                )
                logTouchEvent(action: "dragEnd", viewPt: endedPt ?? lastLocationInOwnView, virtualPt: releasePt)
                if activeTouches.isEmpty {
                    mode = .idle
                    state = .ended
                }
            }

        case let .twoFinger(idA, idB, anchorVirtualPt, _, _, _, _, _, _, startTime, _, subMode, rotateBegan):
            let aEnded = ended.contains(where: { $0.identity.isEqual(idA) })
            let bEnded = ended.contains(where: { $0.identity.isEqual(idB) })
            if aEnded || bEnded || activeTouches.isEmpty {
                switch subMode {
                case .undecided:
                    if activeTouches.isEmpty && (event.timestamp - startTime) < 0.45 {
                        SidecarTouchRemapper.postSyntheticMouseEvent(
                            source: eventSource,
                            type: .mouseMoved,
                            button: .right,
                            location: anchorVirtualPt
                        )
                        SidecarTouchRemapper.postSyntheticMouseEvent(
                            source: eventSource,
                            type: .rightMouseDown,
                            button: .right,
                            location: anchorVirtualPt,
                            clickState: 1
                        )
                        SidecarTouchRemapper.postSyntheticMouseEvent(
                            source: eventSource,
                            type: .rightMouseUp,
                            button: .right,
                            location: anchorVirtualPt,
                            clickState: 1
                        )
                        logTouchEvent(action: "twoFingerRightClick", viewPt: lastLocationInOwnView, virtualPt: anchorVirtualPt)
                    }
                case .scrolling:
                    SidecarTouchRemapper.postSyntheticScrollEvent(
                        source: eventSource,
                        location: anchorVirtualPt,
                        axis1: 0,
                        axis2: 0,
                        scrollPhase: .ended
                    )
                    startMomentumIfFast(anchor: anchorVirtualPt, endTimestamp: event.timestamp)
                case .pinching:
                    SidecarTouchRemapper.postSyntheticGestureEvent(
                        source: eventSource,
                        kind: .zoom,
                        phase: .ended,
                        location: anchorVirtualPt,
                        value: 0.0
                    )
                    if rotateBegan {
                        SidecarTouchRemapper.postSyntheticGestureEvent(
                            source: eventSource,
                            kind: .rotate,
                            phase: .ended,
                            location: anchorVirtualPt,
                            value: 0.0
                        )
                    }
                    logTouchEvent(action: "pinchEnded", viewPt: lastLocationInOwnView, virtualPt: anchorVirtualPt)
                }
                if activeTouches.isEmpty {
                    mode = .idle
                    state = .ended
                }
            }
        }

        if activeTouches.isEmpty && mode != .idle {
            cancelPendingDragTimer()
            mode = .idle
            state = (state == .began || state == .changed) ? .ended : .failed
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        cancelPendingDragTimer()
        stopMomentum(emitEnd: false)
        switch mode {
        case let .draggingOneFinger(_, lastVirtualPt, clickState):
            SidecarTouchRemapper.postSyntheticMouseEvent(
                source: eventSource,
                type: .leftMouseUp,
                button: .left,
                location: lastVirtualPt,
                clickState: clickState
            )
        case let .scrollingOneFinger(_, anchorVirtualPt, _, _):
            SidecarTouchRemapper.postSyntheticScrollEvent(
                source: eventSource,
                location: anchorVirtualPt,
                axis1: 0,
                axis2: 0,
                scrollPhase: .cancelled
            )
        case let .twoFinger(_, _, anchorVirtualPt, _, _, _, _, _, _, _, _, subMode, rotateBegan):
            if subMode == .scrolling {
                SidecarTouchRemapper.postSyntheticScrollEvent(
                    source: eventSource,
                    location: anchorVirtualPt,
                    axis1: 0,
                    axis2: 0,
                    scrollPhase: .cancelled
                )
            } else if subMode == .pinching {
                SidecarTouchRemapper.postSyntheticGestureEvent(
                    source: eventSource,
                    kind: .zoom,
                    phase: .cancelled,
                    location: anchorVirtualPt,
                    value: 0.0
                )
                if rotateBegan {
                    SidecarTouchRemapper.postSyntheticGestureEvent(
                        source: eventSource,
                        kind: .rotate,
                        phase: .cancelled,
                        location: anchorVirtualPt,
                        value: 0.0
                    )
                }
            }
        case .idle, .pendingOneFinger:
            break
        }
        activeTouches.removeAll()
        mode = .idle
        resetScrollKinematics()
        state = (state == .began || state == .changed) ? .cancelled : .failed
    }

    // MARK: - Fallback Mouse / Tablet / Scroll Forwarding on Overlay

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        forwardFallbackMouseDown(event, button: .left, cgType: .leftMouseDown)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        forwardFallbackMouseDragged(event, button: .left, cgType: .leftMouseDragged)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        forwardFallbackMouseUp(event, button: .left, cgType: .leftMouseUp)
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        forwardFallbackMouseDown(event, button: .right, cgType: .rightMouseDown)
    }

    override func rightMouseDragged(with event: NSEvent) {
        super.rightMouseDragged(with: event)
        forwardFallbackMouseDragged(event, button: .right, cgType: .rightMouseDragged)
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        forwardFallbackMouseUp(event, button: .right, cgType: .rightMouseUp)
    }

    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
        forwardFallbackMouseDown(event, button: .center, cgType: .otherMouseDown)
    }

    override func otherMouseDragged(with event: NSEvent) {
        super.otherMouseDragged(with: event)
        forwardFallbackMouseDragged(event, button: .center, cgType: .otherMouseDragged)
    }

    override func otherMouseUp(with event: NSEvent) {
        super.otherMouseUp(with: event)
        forwardFallbackMouseUp(event, button: .center, cgType: .otherMouseUp)
    }

    override func tabletPoint(with event: NSEvent) {
        super.tabletPoint(with: event)
        guard activeTouches.isEmpty, let view = self.view else { return }
        let pt = view.convert(event.locationInWindow, from: nil)
        guard let vPt = mapViewPoint(pt) else { return }
        lastLocationInOwnView = pt
        SidecarTouchRemapper.postSyntheticMouseEvent(
            source: eventSource,
            type: .mouseMoved,
            button: .left,
            location: vPt
        )
    }

    func handleOverlayScrollWheel(_ event: NSEvent) -> Bool {
        guard let view = self.view else { return false }
        let pt = view.convert(event.locationInWindow, from: nil)
        guard let vPt = mapViewPoint(pt) else { return false }
        let geo = geometryProvider()
        let rawY = Int64(event.scrollingDeltaY.rounded())
        let rawX = Int64(event.scrollingDeltaX.rounded())
        guard rawX != 0 || rawY != 0 else { return true }
        let rotated = SidecarInputTransform.rotateScrollAxesInt(
            axis1: rawY,
            axis2: rawX,
            rotationDegrees: geo.rotationDegrees
        )
        SidecarTouchRemapper.postSyntheticScrollEvent(
            source: eventSource,
            location: vPt,
            axis1: Int32(clamping: rotated.axis1),
            axis2: Int32(clamping: rotated.axis2)
        )
        return true
    }

    // MARK: - Helpers

    private func startTwoFingerMode(timestamp: TimeInterval) {
        guard activeTouches.count >= 2 else { return }
        let a = activeTouches[0]
        let b = activeTouches[1]
        guard let vpA = mapViewPoint(a.point),
              let vpB = mapViewPoint(b.point) else { return }

        let centroidView = NSPoint(x: (a.point.x + b.point.x) * 0.5, y: (a.point.y + b.point.y) * 0.5)
        let centroidVirtual = CGPoint(x: (vpA.x + vpB.x) * 0.5, y: (vpA.y + vpB.y) * 0.5)
        let span = max(hypot(vpB.x - vpA.x, vpB.y - vpA.y), 1.0)
        let angle = atan2(vpB.y - vpA.y, vpB.x - vpA.x)

        lastLocationInOwnView = centroidView
        resetScrollKinematics()
        mode = .twoFinger(
            idA: a.identity,
            idB: b.identity,
            anchorVirtualPt: centroidVirtual,
            initialCentroidVirtual: centroidVirtual,
            lastCentroidVirtual: centroidVirtual,
            initialSpan: span,
            lastSpan: span,
            initialAngleRad: angle,
            lastAngleRad: angle,
            startTime: timestamp,
            lastTimestamp: timestamp,
            subMode: .undecided,
            rotateBegan: false
        )
        state = .began
        logTouchEvent(action: "began2", viewPt: centroidView, virtualPt: centroidVirtual)
    }

    private func shouldOneFingerMoveImmediatelyDrag(at virtualPt: CGPoint) -> Bool {
        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(systemWideAX, Float(virtualPt.x), Float(virtualPt.y), &hit)
        guard err == .success, let element = hit else { return false }

        if let role = copyStringAttr(kAXRoleAttribute as CFString, from: element) {
            if Self.dragPriorityRoles.contains(role) {
                return true
            }
            if (role == (kAXStaticTextRole as String) || role == (kAXImageRole as String)),
               let parent = copyElementAttr(kAXParentAttribute as CFString, from: element),
               let parentRole = copyStringAttr(kAXRoleAttribute as CFString, from: parent),
               Self.dragPriorityRoles.contains(parentRole) {
                return true
            }
        }

        if let win = copyElementAttr(kAXWindowAttribute as CFString, from: element),
           let winPos = copyPointAttr(kAXPositionAttribute as CFString, from: win) {
            let localY = virtualPt.y - winPos.y
            if localY >= 0 && localY <= 44.0 {
                return true
            }
        }
        return false
    }

    private func copyStringAttr(_ attr: CFString, from element: AXUIElement) -> String? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &val) == .success else { return nil }
        return val as? String
    }

    private func copyElementAttr(_ attr: CFString, from element: AXUIElement) -> AXUIElement? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &val) == .success, let val else { return nil }
        guard CFGetTypeID(val) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(val as AnyObject, to: AXUIElement.self)
    }

    private func copyPointAttr(_ attr: CFString, from element: AXUIElement) -> CGPoint? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &val) == .success, let val else { return nil }
        guard CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        let axVal = unsafeDowncast(val as AnyObject, to: AXValue.self)
        var pt = CGPoint.zero
        guard AXValueGetValue(axVal, .cgPoint, &pt) else { return nil }
        return pt
    }

    private func emitContinuousScrollStep(
        anchor: CGPoint,
        dx: Double,
        dy: Double,
        dt: TimeInterval,
        timestamp: TimeInterval,
        phase: CGScrollPhase
    ) {
        if dt > 0.001 && dt < 0.15 {
            let instVX = min(max(dx / dt, -3500), 3500)
            let instVY = min(max(dy / dt, -3500), 3500)
            scrollVelocityX = scrollVelocityX * 0.55 + instVX * 0.45
            scrollVelocityY = scrollVelocityY * 0.55 + instVY * 0.45
            lastScrollSampleTime = timestamp
        }
        scrollRemainderX += dx
        scrollRemainderY += dy
        let ix = Int32(scrollRemainderX)
        let iy = Int32(scrollRemainderY)
        scrollRemainderX -= Double(ix)
        scrollRemainderY -= Double(iy)
        if ix != 0 || iy != 0 {
            SidecarTouchRemapper.postSyntheticScrollEvent(
                source: eventSource,
                location: anchor,
                axis1: iy,
                axis2: ix,
                scrollPhase: phase
            )
        }
    }

    private func resetScrollKinematics() {
        scrollRemainderX = 0
        scrollRemainderY = 0
        scrollVelocityX = 0
        scrollVelocityY = 0
        lastScrollSampleTime = -1
    }

    private func startMomentumIfFast(anchor: CGPoint, endTimestamp: TimeInterval) {
        guard lastScrollSampleTime >= 0, (endTimestamp - lastScrollSampleTime) < 0.06 else {
            resetScrollKinematics()
            return
        }
        let speed = hypot(scrollVelocityX, scrollVelocityY)
        guard speed > 140.0 else {
            resetScrollKinematics()
            return
        }

        stopMomentum(emitEnd: false)
        momentumAnchorPt = anchor
        momentumStarted = false
        let dt = 0.016
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + dt, repeating: dt)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.scrollVelocityX *= 0.92
            self.scrollVelocityY *= 0.92
            if hypot(self.scrollVelocityX, self.scrollVelocityY) < 25.0 {
                self.stopMomentum(emitEnd: true)
                return
            }
            self.scrollRemainderX += self.scrollVelocityX * dt
            self.scrollRemainderY += self.scrollVelocityY * dt
            let ix = Int32(self.scrollRemainderX)
            let iy = Int32(self.scrollRemainderY)
            self.scrollRemainderX -= Double(ix)
            self.scrollRemainderY -= Double(iy)
            guard ix != 0 || iy != 0 else { return }
            let phase: CGMomentumScrollPhase = self.momentumStarted ? .continuous : .begin
            self.momentumStarted = true
            SidecarTouchRemapper.postSyntheticScrollEvent(
                source: self.eventSource,
                location: self.momentumAnchorPt,
                axis1: iy,
                axis2: ix,
                momentumPhase: phase
            )
        }
        momentumTimer = timer
        timer.resume()
    }

    private func stopMomentum(emitEnd: Bool) {
        if let timer = momentumTimer {
            timer.cancel()
            momentumTimer = nil
            if emitEnd && momentumStarted {
                SidecarTouchRemapper.postSyntheticScrollEvent(
                    source: eventSource,
                    location: momentumAnchorPt,
                    axis1: 0,
                    axis2: 0,
                    momentumPhase: .end
                )
            }
        }
        momentumStarted = false
    }

    private func wrappedAngleDeltaDegrees(from startRad: CGFloat, to endRad: CGFloat) -> Double {
        var delta = endRad - startRad
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        // In Quartz (+Y down), clockwise increases atan2; AppKit NSEvent.rotation is positive CCW.
        return Double(-delta * 180.0 / .pi)
    }

    private func schedulePendingDragTimer(delay: TimeInterval) {
        cancelPendingDragTimer()
        let timer = DispatchWorkItem { [weak self] in
            self?.commitOneFingerDragIfPending(currentViewPt: nil)
        }
        pendingDragWorkItem = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: timer)
    }

    private func cancelPendingDragTimer() {
        pendingDragWorkItem?.cancel()
        pendingDragWorkItem = nil
    }

    private func commitOneFingerDragIfPending(currentViewPt: NSPoint?) {
        cancelPendingDragTimer()
        guard case let .pendingOneFinger(identity, startViewPt, _, _) = mode,
              let vStart = mapViewPoint(startViewPt) else { return }

        let clickCount = nextClickCount(at: vStart)
        SidecarTouchRemapper.postSyntheticMouseEvent(
            source: eventSource,
            type: .mouseMoved,
            button: .left,
            location: vStart
        )
        SidecarTouchRemapper.postSyntheticMouseEvent(
            source: eventSource,
            type: .leftMouseDown,
            button: .left,
            location: vStart,
            clickState: clickCount
        )

        var latestVirtual = vStart
        if let pt = currentViewPt ?? pointForTouch(identity: identity),
           let vCurr = mapViewPoint(pt) {
            lastLocationInOwnView = pt
            let dx = Int64((vCurr.x - vStart.x).rounded())
            let dy = Int64((vCurr.y - vStart.y).rounded())
            if dx != 0 || dy != 0 {
                SidecarTouchRemapper.postSyntheticMouseEvent(
                    source: eventSource,
                    type: .leftMouseDragged,
                    button: .left,
                    location: vCurr,
                    clickState: clickCount,
                    deltaX: dx,
                    deltaY: dy
                )
            }
            latestVirtual = vCurr
        }

        mode = .draggingOneFinger(identity: identity, lastVirtualPt: latestVirtual, clickState: clickCount)
        state = .began
        logTouchEvent(action: "dragStart(\(clickCount))", viewPt: startViewPt, virtualPt: vStart)
    }

    private func shouldIgnoreFallbackMouse(_ event: NSEvent) -> Bool {
        if !activeTouches.isEmpty { return true }
        if event.subtype != .tabletPoint,
           lastDirectTouchTimestamp >= 0,
           abs(event.timestamp - lastDirectTouchTimestamp) < 0.15 {
            return true
        }
        return false
    }

    private func forwardFallbackMouseDown(_ event: NSEvent, button: CGMouseButton, cgType: CGEventType) {
        guard !shouldIgnoreFallbackMouse(event), let view = self.view else { return }
        let pt = view.convert(event.locationInWindow, from: nil)
        guard let vPt = mapViewPoint(pt) else { return }
        lastLocationInOwnView = pt
        activeFallbackButton = button
        lastFallbackVirtualPt = vPt
        SidecarTouchRemapper.postSyntheticMouseEvent(
            source: eventSource,
            type: .mouseMoved,
            button: button,
            location: vPt
        )
        SidecarTouchRemapper.postSyntheticMouseEvent(
            source: eventSource,
            type: cgType,
            button: button,
            location: vPt,
            clickState: Int64(max(1, event.clickCount))
        )
        state = .began
        logTouchEvent(action: "mouseDown(\(button.rawValue))", viewPt: pt, virtualPt: vPt)
    }

    private func forwardFallbackMouseDragged(_ event: NSEvent, button: CGMouseButton, cgType: CGEventType) {
        guard activeFallbackButton == button, let view = self.view else { return }
        let pt = view.convert(event.locationInWindow, from: nil)
        guard let vPt = mapViewPoint(pt) else { return }
        lastLocationInOwnView = pt
        let dx = Int64((vPt.x - lastFallbackVirtualPt.x).rounded())
        let dy = Int64((vPt.y - lastFallbackVirtualPt.y).rounded())
        lastFallbackVirtualPt = vPt
        SidecarTouchRemapper.postSyntheticMouseEvent(
            source: eventSource,
            type: cgType,
            button: button,
            location: vPt,
            clickState: Int64(max(1, event.clickCount)),
            deltaX: dx,
            deltaY: dy
        )
        state = .changed
    }

    private func forwardFallbackMouseUp(_ event: NSEvent, button: CGMouseButton, cgType: CGEventType) {
        guard activeFallbackButton == button, let view = self.view else { return }
        activeFallbackButton = nil
        let pt = view.convert(event.locationInWindow, from: nil)
        let vPt = mapViewPoint(pt) ?? lastFallbackVirtualPt
        lastLocationInOwnView = pt
        SidecarTouchRemapper.postSyntheticMouseEvent(
            source: eventSource,
            type: cgType,
            button: button,
            location: vPt,
            clickState: Int64(max(1, event.clickCount))
        )
        state = .ended
    }

    private func syncTouches(from event: NSEvent) -> [(identity: NSObject, point: NSPoint)] {
        guard let view = self.view else { return [] }
        let viewTouches = event.touches(matching: .any, in: view)
        let rawTouches = viewTouches.isEmpty ? event.allTouches() : viewTouches
        var endedList: [(identity: NSObject, point: NSPoint)] = []

        for touch in rawTouches where touch.type == .direct {
            guard let idObj = touch.identity as? NSObject else { continue }
            let pt = touchLocation(touch, in: view)
            if touch.phase == .ended || touch.phase == .cancelled {
                activeTouches.removeAll { $0.identity.isEqual(idObj) }
                endedList.append((idObj, pt))
            } else {
                if let idx = activeTouches.firstIndex(where: { $0.identity.isEqual(idObj) }) {
                    activeTouches[idx].point = pt
                } else {
                    activeTouches.append((idObj, pt))
                }
            }
        }
        return endedList
    }

    private func touchLocation(_ touch: NSTouch, in view: NSView) -> NSPoint {
        let directPt = touch.location(in: view)
        if directPt.x.isFinite && directPt.y.isFinite && view.bounds.width > 0 && view.bounds.height > 0 {
            return directPt
        }
        let norm = touch.normalizedPosition
        return NSPoint(
            x: norm.x * view.bounds.width,
            y: norm.y * view.bounds.height
        )
    }

    private func pointForTouch(identity: NSObject) -> NSPoint? {
        activeTouches.first(where: { $0.identity.isEqual(identity) })?.point
    }

    private func mapViewPoint(_ viewPoint: NSPoint) -> CGPoint? {
        guard let view = self.view, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let geo = geometryProvider()
        guard geo.isActive, !geo.hiddenBounds.isNull, !geo.virtualBounds.isNull else { return nil }

        let nx = min(max(Double(viewPoint.x / view.bounds.width), 0.0), 0.99999)
        let ny = min(max(1.0 - Double(viewPoint.y / view.bounds.height), 0.0), 0.99999)
        let hiddenPt = CGPoint(
            x: geo.hiddenBounds.minX + nx * geo.hiddenBounds.width,
            y: geo.hiddenBounds.minY + ny * geo.hiddenBounds.height
        )
        return SidecarInputTransform.mapPoint(
            hiddenPt,
            from: geo.hiddenBounds,
            to: geo.virtualBounds,
            rotationDegrees: geo.rotationDegrees
        )
    }

    private func nextClickCount(at virtualPt: CGPoint) -> Int64 {
        let now = ProcessInfo.processInfo.systemUptime
        if (now - lastClickUptime) <= NSEvent.doubleClickInterval,
           hypot(virtualPt.x - lastClickVirtualPt.x, virtualPt.y - lastClickVirtualPt.y) <= 24.0 {
            clickSequenceCount += 1
        } else {
            clickSequenceCount = 1
        }
        lastClickUptime = now
        lastClickVirtualPt = virtualPt
        return clickSequenceCount
    }

    private func logTouchEvent(action: String, viewPt: NSPoint, virtualPt: CGPoint? = nil) {
        guard loggedTouchCount < 16 else { return }
        loggedTouchCount += 1
        if let virtualPt {
            SidecarTouchRemapper.logger.notice("DirectTouch \(action, privacy: .public) view=(\(viewPt.x, privacy: .public),\(viewPt.y, privacy: .public)) -> virtual=(\(virtualPt.x, privacy: .public),\(virtualPt.y, privacy: .public))")
        } else {
            SidecarTouchRemapper.logger.notice("DirectTouch \(action, privacy: .public) view=(\(viewPt.x, privacy: .public),\(viewPt.y, privacy: .public))")
        }
    }
}
