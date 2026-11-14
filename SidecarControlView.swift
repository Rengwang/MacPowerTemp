import AppKit
import Foundation

/// Compact menu card UI for Sidecar vertical mode, styled consistently with `PowerControlView`.
final class SidecarControlView: NSView {
    struct ViewState {
        var isVertical: Bool = false
        var transitionState: SidecarController.TransitionState = .idle
        var hasSidecar: Bool = false
        var hasPermission: Bool = true
        var hasAccessibilityPermission: Bool = true
        var isTouchRemappingActive: Bool = false
        var deviceName: String? = nil
        var activeSummary: String? = nil
        var statusText: String = "快捷键 Ctrl+Opt+V 快速切换横/竖屏"
        var presets: [PortraitPreset] = []
        var resolutionIndex: Int = 1
        var rotationDegrees: Int = 270
        var placeOnLeft: Bool = false
        var cursorGuardEnabled: Bool = true
        var hotkeyEnabled: Bool = true

        var isTransitioning: Bool { transitionState != .idle }
    }

    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "iPad 随航")
    private let subLabel = NSTextField(labelWithString: "无线/有线扩展")
    private let statusBadge = NSTextField(labelWithString: "未连接")

    private let horizontalButton = NSButton(title: "连接横屏", target: nil, action: nil)
    private let verticalButton = NSButton(title: "连接竖屏", target: nil, action: nil)
    private let flipButton = NSButton(title: "↻ 270°", target: nil, action: nil)

    private var presetButtons: [NSButton] = []
    private let sideButton = NSButton(title: "位置: 右侧", target: nil, action: nil)
    private let guardButton = NSButton(title: "防误触: 开", target: nil, action: nil)
    private let utilityButton = NSButton(title: "热键: 开", target: nil, action: nil)
    private let footerLabel = NSTextField(labelWithString: "快捷键 Ctrl+Opt+V 快速切换横/竖屏")

    private var state = ViewState()

    var onConnectHorizontal: (() -> Void)?
    var onToggleVertical: (() -> Void)?
    var onFlip180: (() -> Void)?
    var onSelectResolution: ((Int) -> Void)?
    var onTogglePlacement: (() -> Void)?
    var onToggleCursorGuard: (() -> Void)?
    var onDisconnectSidecar: (() -> Void)?
    var onToggleHotkey: (() -> Void)?
    var onRequestPermission: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 304, height: 162))
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func stylePillButton(_ btn: NSButton, fontSize: CGFloat, weight: NSFont.Weight = .medium, radius: CGFloat = 6) {
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = radius
        btn.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        btn.alignment = .center
    }

    private func setupUI() {
        wantsLayer = true

        card.frame = NSRect(x: 10, y: 4, width: 284, height: 154)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 0.75
        addSubview(card)

        // Header
        titleLabel.frame = NSRect(x: 12, y: 123, width: 62, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        card.addSubview(titleLabel)

        subLabel.frame = NSRect(x: 72, y: 124, width: 104, height: 15)
        subLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        subLabel.textColor = .tertiaryLabelColor
        subLabel.lineBreakMode = .byTruncatingTail
        card.addSubview(subLabel)

        statusBadge.frame = NSRect(x: 180, y: 122, width: 92, height: 19)
        statusBadge.alignment = .center
        statusBadge.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = 6
        card.addSubview(statusBadge)

        // Primary action row: native Horizontal + Portrait Virtual + 180° Flip
        horizontalButton.frame = NSRect(x: 12, y: 84, width: 94, height: 30)
        stylePillButton(horizontalButton, fontSize: 11.5, weight: .semibold, radius: 7)
        horizontalButton.target = self
        horizontalButton.action = #selector(horizontalTapped)
        card.addSubview(horizontalButton)

        verticalButton.frame = NSRect(x: 111, y: 84, width: 94, height: 30)
        stylePillButton(verticalButton, fontSize: 11.5, weight: .semibold, radius: 7)
        verticalButton.target = self
        verticalButton.action = #selector(verticalTapped)
        card.addSubview(verticalButton)

        flipButton.frame = NSRect(x: 210, y: 84, width: 62, height: 30)
        stylePillButton(flipButton, fontSize: 11.0, weight: .semibold, radius: 7)
        flipButton.toolTip = "旋转 180° 校正竖屏显示方向（iPad 竖屏锁与横屏锁之间切换）"
        flipButton.target = self
        flipButton.action = #selector(flipTapped)
        card.addSubview(flipButton)

        // Portrait HiDPI preset row (4 buttons spanning 12..271)
        let pw: CGFloat = 61
        let gap: CGFloat = 5
        let startX: CGFloat = 12
        for idx in 0..<4 {
            let b = NSButton(title: "原生 1:1", target: self, action: #selector(presetTapped(_:)))
            b.tag = idx
            b.frame = NSRect(x: startX + CGFloat(idx) * (pw + gap), y: 56, width: pw, height: 22)
            stylePillButton(b, fontSize: 10.5, weight: .semibold)
            card.addSubview(b)
            presetButtons.append(b)
        }

        // Options row (placement + cursor guard + disconnect/permission/hotkey)
        sideButton.frame = NSRect(x: 12, y: 29, width: 84, height: 21)
        stylePillButton(sideButton, fontSize: 10.5, weight: .medium)
        sideButton.toolTip = "设置竖屏扩展桌面位于主屏的左侧还是右侧"
        sideButton.target = self
        sideButton.action = #selector(sideTapped)
        card.addSubview(sideButton)

        guardButton.frame = NSRect(x: 101, y: 29, width: 88, height: 21)
        stylePillButton(guardButton, fontSize: 10.5, weight: .medium)
        guardButton.toolTip = "防止光标滑入隐藏的原生随航屏区域"
        guardButton.target = self
        guardButton.action = #selector(guardTapped)
        card.addSubview(guardButton)

        utilityButton.frame = NSRect(x: 194, y: 29, width: 78, height: 21)
        stylePillButton(utilityButton, fontSize: 10.5, weight: .medium)
        utilityButton.target = self
        utilityButton.action = #selector(utilityTapped)
        card.addSubview(utilityButton)

        // Footer
        footerLabel.frame = NSRect(x: 12, y: 9, width: 260, height: 15)
        footerLabel.font = NSFont.systemFont(ofSize: 10.0)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail
        footerLabel.maximumNumberOfLines = 1
        card.addSubview(footerLabel)

        refreshThemeAndState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshThemeAndState()
    }

    func update(_ newState: ViewState) {
        self.state = newState
        refreshThemeAndState()
    }

    private func setStyledTitle(_ btn: NSButton, _ title: String, color: NSColor) {
        btn.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: btn.font!, .foregroundColor: color]
        )
    }

    private func refreshThemeAndState() {
        card.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        subLabel.stringValue = state.deviceName ?? "无线/有线扩展"
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let greenFg = isDark ? NSColor.systemGreen : NSColor(srgbRed: 0.11, green: 0.54, blue: 0.24, alpha: 1)

        // Status badge
        switch state.transitionState {
        case .connectingHorizontal:
            statusBadge.stringValue = "连横屏中…"
            statusBadge.textColor = .white
            statusBadge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        case .startingVertical:
            statusBadge.stringValue = "切竖屏中…"
            statusBadge.textColor = .white
            statusBadge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        case .idle:
            if state.isVertical {
                statusBadge.stringValue = (state.activeSummary?.contains("1x") == true) ? "竖屏 1x" : "竖屏 HiDPI"
                statusBadge.textColor = .white
                statusBadge.layer?.backgroundColor = NSColor.systemBlue.cgColor
            } else if state.hasSidecar {
                statusBadge.stringValue = "原生横屏"
                statusBadge.textColor = greenFg
                statusBadge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.16).cgColor
            } else if !state.hasPermission {
                statusBadge.stringValue = "待录屏授权"
                statusBadge.textColor = .black
                statusBadge.layer?.backgroundColor = StatusImage.amber.cgColor
            } else {
                statusBadge.stringValue = "未连接"
                statusBadge.textColor = .secondaryLabelColor
                statusBadge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            }
        }

        // Primary row buttons
        let busy = state.isTransitioning
        horizontalButton.isEnabled = !busy
        verticalButton.isEnabled = !busy

        // 1. Horizontal button (native Sidecar — no virtual display)
        if state.transitionState == .connectingHorizontal {
            horizontalButton.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.16).cgColor
            setStyledTitle(horizontalButton, "连接中…", color: .systemBlue)
            horizontalButton.toolTip = "正在直接发起原生随航连接（无虚拟屏开销）"
        } else if state.hasSidecar && !state.isVertical {
            horizontalButton.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.18).cgColor
            setStyledTitle(horizontalButton, "✓ 原生横屏", color: greenFg)
            horizontalButton.toolTip = "当前已连接为系统原生横屏随航（未创建虚拟屏）"
        } else if state.isVertical {
            horizontalButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            setStyledTitle(horizontalButton, "切回横屏", color: .labelColor)
            horizontalButton.toolTip = "关闭竖屏虚拟屏，恢复纯原生横屏随航"
        } else {
            let ready = state.deviceName != nil && !busy
            horizontalButton.layer?.backgroundColor = ready
                ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
                : NSColor.labelColor.withAlphaComponent(0.08).cgColor
            setStyledTitle(horizontalButton, "连接横屏", color: ready ? .controlAccentColor : .labelColor)
            horizontalButton.toolTip = "直接调用系统原生随航连接 iPad（横屏扩展，无需新建虚拟屏）"
        }

        // 2. Vertical button (HiDPI virtual portrait)
        if state.transitionState == .startingVertical {
            verticalButton.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.16).cgColor
            setStyledTitle(verticalButton, "开启中…", color: .systemBlue)
            verticalButton.toolTip = "正在创建竖屏 HiDPI 虚拟屏并启动画面采集"
        } else if state.isVertical {
            verticalButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
            setStyledTitle(verticalButton, "✓ 竖屏已开", color: .white)
            verticalButton.toolTip = "当前为 HiDPI 竖屏模式，再次点击或按 Ctrl+Opt+V 可切回横屏"
        } else if !state.hasPermission {
            verticalButton.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.18).cgColor
            setStyledTitle(verticalButton, "竖屏(授权)", color: .systemOrange)
            verticalButton.toolTip = "竖屏模式需先授予「屏幕录制与系统录音」权限"
        } else if state.hasSidecar {
            verticalButton.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            setStyledTitle(verticalButton, "开启竖屏", color: .controlAccentColor)
            verticalButton.toolTip = "将当前横屏随航切换为 HiDPI 竖屏模式（Ctrl+Opt+V）"
        } else {
            let ready = state.deviceName != nil && !busy
            verticalButton.layer?.backgroundColor = ready
                ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
                : NSColor.labelColor.withAlphaComponent(0.08).cgColor
            setStyledTitle(verticalButton, "连接竖屏", color: ready ? .controlAccentColor : .labelColor)
            verticalButton.toolTip = "连接随航并直接启用 HiDPI 竖屏模式（Ctrl+Opt+V）"
        }

        // 3. 180° flip button
        let flipText = "↻ \(state.rotationDegrees)°"
        if state.isVertical {
            flipButton.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.16).cgColor
            setStyledTitle(flipButton, flipText, color: .systemBlue)
        } else {
            flipButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            setStyledTitle(flipButton, flipText, color: .labelColor)
        }

        // Preset buttons
        for (idx, b) in presetButtons.enumerated() {
            let preset = idx < state.presets.count ? state.presets[idx] : nil
            let label = preset?.shortTitle ?? "预设 \(idx + 1)"
            b.toolTip = preset.map { "\($0.title) HiDPI" }
            let isSelected = idx == state.resolutionIndex
            if state.isVertical && isSelected {
                b.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                setStyledTitle(b, label, color: .white)
            } else if isSelected {
                b.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                setStyledTitle(b, label, color: .controlAccentColor)
            } else {
                b.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
                setStyledTitle(b, label, color: .labelColor)
            }
        }

        // Side & cursor guard pills
        sideButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        setStyledTitle(sideButton, state.placeOnLeft ? "位置: 左侧" : "位置: 右侧", color: .labelColor)

        if state.isVertical && !state.isTouchRemappingActive {
            guardButton.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.18).cgColor
            setStyledTitle(guardButton, "触控(授权)", color: .systemOrange)
            guardButton.toolTip = state.hasAccessibilityPermission
                ? "触控映射未就绪，点击重试或检查「辅助功能」权限"
                : "竖屏触控与 Apple Pencil 映射需授予「辅助功能」权限，点击前往系统设置"
        } else if state.cursorGuardEnabled {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let fg = isDark ? NSColor.systemGreen : NSColor(srgbRed: 0.11, green: 0.54, blue: 0.24, alpha: 1)
            guardButton.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.15).cgColor
            setStyledTitle(guardButton, "防误触: 开", color: fg)
            guardButton.toolTip = state.isTouchRemappingActive
                ? "防止光标滑入隐藏的原生随航屏区域（竖屏触控映射已启用）"
                : "防止光标滑入隐藏的原生随航屏区域"
        } else {
            guardButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            setStyledTitle(guardButton, "防误触: 关", color: .secondaryLabelColor)
            guardButton.toolTip = state.isTouchRemappingActive
                ? "防误触已关闭（竖屏触控映射仍保持启用）"
                : "防止光标滑入隐藏的原生随航屏区域"
        }

        // Rightmost utility pill (always show Disconnect when Sidecar is connected)
        if state.hasSidecar || state.isVertical {
            utilityButton.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.14).cgColor
            setStyledTitle(utilityButton, "断开随航", color: .systemRed)
            utilityButton.toolTip = "关闭竖屏虚拟屏（如有）并断开 iPad 随航连接"
        } else if !state.hasPermission {
            utilityButton.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.18).cgColor
            setStyledTitle(utilityButton, "录屏设置", color: .systemOrange)
            utilityButton.toolTip = "打开系统设置授予屏幕录制权限"
        } else {
            utilityButton.layer?.backgroundColor = state.hotkeyEnabled
                ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
                : NSColor.labelColor.withAlphaComponent(0.08).cgColor
            setStyledTitle(
                utilityButton,
                state.hotkeyEnabled ? "热键: 开" : "热键: 关",
                color: state.hotkeyEnabled ? .controlAccentColor : .secondaryLabelColor
            )
            utilityButton.toolTip = "点击开启或关闭全局快捷键 Ctrl+Option+V"
        }

        // Footer text
        footerLabel.stringValue = state.statusText
        footerLabel.toolTip = state.statusText
    }

    @objc private func horizontalTapped() {
        onConnectHorizontal?()
    }

    @objc private func verticalTapped() {
        if !state.hasPermission && !state.isVertical {
            enclosingMenuItem?.menu?.cancelTracking()
            DispatchQueue.main.async { [weak self] in
                self?.onRequestPermission?()
            }
            return
        }
        onToggleVertical?()
    }

    @objc private func flipTapped() {
        onFlip180?()
    }

    @objc private func presetTapped(_ sender: NSButton) {
        onSelectResolution?(sender.tag)
    }

    @objc private func sideTapped() {
        onTogglePlacement?()
    }

    @objc private func guardTapped() {
        if state.isVertical && !state.isTouchRemappingActive {
            enclosingMenuItem?.menu?.cancelTracking()
            DispatchQueue.main.async { [weak self] in
                self?.onRequestAccessibility?()
            }
            return
        }
        onToggleCursorGuard?()
    }

    @objc private func utilityTapped() {
        if state.hasSidecar || state.isVertical {
            onDisconnectSidecar?()
        } else if !state.hasPermission {
            enclosingMenuItem?.menu?.cancelTracking()
            DispatchQueue.main.async { [weak self] in
                self?.onRequestPermission?()
            }
        } else {
            onToggleHotkey?()
        }
    }
}
