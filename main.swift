import AppKit
import Foundation

// MARK: - 常量
let kLoginAgentLabel = "com.workbuddy.macpowertemp"

// MARK: - 可调参数
enum TextSize: Int, CaseIterable {
    case small = 0, medium = 1, large = 2

    var title: String {
        switch self {
        case .small:  return "小"
        case .medium: return "中"
        case .large:  return "大"
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small:  return 9.5
        case .medium: return 10.5
        case .large:  return 12.0
        }
    }

    var itemWidth: CGFloat {
        switch self {
        case .small:  return 31
        case .medium: return 34
        case .large:  return 37
        }
    }
}

enum ColorMode: Int {
    case mono = 0      // 模板图，系统自动反色，对比最高
    case warmText = 1  // 彩色字（对比偏弱，但保留）
    case chip = 2      // 黑字 + 彩色底块

    var title: String {
        switch self {
        case .mono:     return "单色（最清晰）"
        case .warmText: return "彩色文字（对比弱）"
        case .chip:     return "色块（黑字彩底，最醒目）"
        }
    }
}

// MARK: - 采样模型
struct Reading {
    var powerW: Double?
    var chipW: Double?
    var batteryW: Double?
    var tempC: Double?
    var tempSensor: String?
    var sensorCount: Int = 0
    var onAC: Bool = false
    var pkgCapW: Double?      // nil = 无限制
    var gpuCapMW: Int64?
}

// Menu-only sensor: opening takes a fresh reading; closing drops it and stops reads.
final class MenuChipPowerSampler {
    private(set) var isOpen = false
    private let read: () -> Double

    init(read: @escaping () -> Double = { sensors_chip_w() }) { self.read = read }
    func open() { isOpen = true }
    func close() { isOpen = false }
    func sample() -> Double? {
        guard isOpen else { return nil }
        let watts = read()
        return watts.isFinite && watts >= 0 ? watts : nil
    }
}

private let socExcludeTokens = ["tcal", "tdev", "gas gauge", "battery", "nand", "airport",
                                "ambient", "ssd", "enclosure", "skin"]
private let socHintTokens = ["tdie", "cpu", "gpu", "soc", "eacc", "pacc", "core", "die"]
private let fallbackExcludeTokens = ["gas gauge", "battery", "nand", "tcal"]
private let sampleBufferLock = NSLock()
private var sampleSensorScratch = [TempSensor](repeating: TempSensor(), count: 200)

func isSoCSensor(_ raw: String) -> Bool {
    let n = raw.lowercased()
    if socExcludeTokens.contains(where: { n.contains($0) }) { return false }
    return socHintTokens.contains(where: { n.contains($0) })
}

func takeSample() -> Reading {
    var r = Reading()

    sampleBufferLock.lock()
    let count = sampleSensorScratch.withUnsafeMutableBufferPointer { buf in
        Int(sensors_read_temperatures(buf.baseAddress, Int32(buf.count)))
    }
    r.sensorCount = count

    var bestSoC: (String, Double)?
    var bestAny: (String, Double)?
    for i in 0..<count {
        let name = sensor_name(&sampleSensorScratch[i]).map { String(cString: $0) } ?? "unknown"
        let v = sampleSensorScratch[i].value
        if isSoCSensor(name), v > 0 {
            if bestSoC == nil || v > bestSoC!.1 { bestSoC = (name, v) }
        }
        let ln = name.lowercased()
        let okForFallback = !fallbackExcludeTokens.contains(where: { ln.contains($0) })
        if okForFallback, v > 0 {
            if bestAny == nil || v > bestAny!.1 { bestAny = (name, v) }
        }
    }
    sampleBufferLock.unlock()

    if let b = bestSoC ?? bestAny {
        r.tempC = b.1
        r.tempSensor = b.0
    }

    let mw = sensors_system_mw()
    if mw > 0 { r.powerW = mw / 1000.0 }

    let bw = sensors_battery_w()
    if bw.isFinite { r.batteryW = bw }

    r.onAC = sensors_on_ac() == 1

    let capW = sensors_pkg_power_cap_w()
    if capW > 0 { r.pkgCapW = capW }
    let gMw = sensors_gpu_power_cap_mw()
    if gMw > 0 { r.gpuCapMW = gMw }
    return r
}

// MARK: - 状态栏图形
enum StatusImage {
    // 亮色：用于色块底、以及深色菜单栏上的文字
    static let amber = NSColor(srgbRed: 1.000, green: 0.769, blue: 0.239, alpha: 1) // #FFC43D
    static let cool  = NSColor(srgbRed: 0.345, green: 0.878, blue: 0.514, alpha: 1) // #58E083
    static let warm  = NSColor(srgbRed: 1.000, green: 0.624, blue: 0.039, alpha: 1) // #FF9F0A
    static let hot   = NSColor(srgbRed: 1.000, green: 0.271, blue: 0.227, alpha: 1) // #FF453A

    static var itemHeight: CGFloat { max(20, NSStatusBar.system.thickness - 2) }

    static func powerText(_ w: Double?) -> String {
        guard let w = w, w > 0 else { return "--" }
        if w >= 100 { return String(format: "%.0fW", w) }
        return String(format: "%.1fW", w)
    }

    static func tempText(_ c: Double?) -> String {
        guard let c = c, c > 0 else { return "--" }
        return String(format: "%.0f°", c)
    }

    /// 温度行后面的休眠状态符号。两个都用单色字形（不是彩色 emoji），
    /// 这样它们会跟随 foregroundColor，和温度数字完全同色。
    /// - 允许休眠（正常）→ ⏾  U+23FE POWER SLEEP（月牙，系统电源睡眠符号）
    /// - 休眠被禁用（盒盖不休眠）→ ⚠  U+26A0（不带 VS16，走文本字形，
    ///   在模板图模式下只有笔画有 alpha，能随菜单栏反色并保持感叹号可见）
    static func sleepBadge(sleepDisabled: Bool) -> String {
        sleepDisabled ? "\u{26A0}" : "\u{23FE}"
    }

    static func capBadge(pkgCapW: Double?, ultra: Bool) -> String {
        if ultra { return "\u{2727}" }        // ✧ 超省电（单色字形）
        if pkgCapW != nil { return "\u{2193}" } // ↓ 已限功率（实心单色箭头，1x 下更清晰）
        return ""
    }

    static func accent(for tempC: Double?) -> NSColor {
        let t = tempC ?? 0
        return t >= 85 ? hot : (t >= 70 ? warm : cool)
    }

    /// 温度行里两段之间的间距
    static let badgeGap: CGFloat = 1.5

    /// 计算实际需要的宽度：行内多了符号，宽度要跟着长。
    static func width(for size: TextSize, mode: ColorMode,
                      power: String, temp: String, badge: String?,
                      powerBadge: String? = nil) -> CGFloat {
        let fontSize = (mode == .chip) ? size.fontSize - 1.2 : size.fontSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let bFont = NSFont.systemFont(ofSize: fontSize)

        var pw = (power as NSString).size(withAttributes: [.font: font]).width
        if let pb = powerBadge, !pb.isEmpty {
            pw += badgeGap + (pb as NSString).size(withAttributes: [.font: bFont]).width
        }
        var tw = (temp as NSString).size(withAttributes: [.font: font]).width
        if let b = badge, !b.isEmpty {
            tw += badgeGap + (b as NSString).size(withAttributes: [.font: bFont]).width
        }
        return max(size.itemWidth, ceil(max(pw, tw)) + 5)
    }

    static func render(power: String, temp: String,
                       mode: ColorMode, tempC: Double?,
                       size: TextSize, badge: String? = nil,
                       powerBadge: String? = nil,
                       monoTint: NSColor? = nil) -> NSImage {
        let w = width(for: size, mode: mode, power: power, temp: temp,
                      badge: badge, powerBadge: powerBadge)
        let h = itemHeight
        let scale: CGFloat = 2

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(w * scale),
                                         pixelsHigh: Int(h * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            return NSImage(size: NSSize(width: w, height: h))
        }
        rep.size = NSSize(width: w, height: h)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        let fontSize = (mode == .chip) ? size.fontSize - 1.2 : size.fontSize
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let cap = font.capHeight

        var powerColor = NSColor.black
        var tempColor = NSColor.black

        switch mode {
        case .mono:
            if let t = monoTint { powerColor = t; tempColor = t }
        case .warmText:
            powerColor = amber
            tempColor = accent(for: tempC)
        case .chip:
            // 两个圆角色块，黑字压在色块上（对比 ≥ 8:1）
            let gap: CGFloat = 1.0
            let ph = (h - gap) / 2
            func pill(_ y: CGFloat, _ color: NSColor) {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: 1, y: y, width: w - 2, height: ph),
                             xRadius: 3, yRadius: 3).fill()
            }
            pill(ph + gap, amber)
            pill(0, accent(for: tempC))
            powerColor = .black
            tempColor = .black
        }

        // 上下两行的中心固定为 3/4 与 1/4 高度
        let base1 = h * 0.75 - cap / 2
        let base2 = h * 0.25 - cap / 2

        // 一行可以由多段组成（温度 + 符号），整行居中
        func drawRow(_ parts: [(String, NSFont)], baseline: CGFloat, color: NSColor) {
            let widths = parts.map { ($0.0 as NSString).size(withAttributes: [.font: $0.1]).width }
            var total: CGFloat = 0
            for i in 0..<widths.count { total += widths[i] + (i > 0 ? badgeGap : 0) }

            var x = (w - total) / 2
            for i in 0..<parts.count {
                if i > 0 { x += badgeGap }
                let f = parts[i].1
                let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
                (parts[i].0 as NSString).draw(at: NSPoint(x: x, y: baseline + f.descender),
                                              withAttributes: attrs)
                x += widths[i]
            }
        }

        var powerRow: [(String, NSFont)] = [(power, font)]
        if let pb = powerBadge, !pb.isEmpty {
            powerRow.append((pb, NSFont.systemFont(ofSize: fontSize)))
        }
        drawRow(powerRow, baseline: base1, color: powerColor)

        var tempRow: [(String, NSFont)] = [(temp, font)]
        if let b = badge, !b.isEmpty {
            tempRow.append((b, NSFont.systemFont(ofSize: fontSize)))
        }
        drawRow(tempRow, baseline: base2, color: tempColor)

        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: NSSize(width: w, height: h))
        img.addRepresentation(rep)
        img.isTemplate = (mode == .mono && monoTint == nil)
        return img
    }
}

// MARK: - 登录时启动
enum LoginItem {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(kLoginAgentLabel).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enable() {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(kLoginAgentLabel)</string>
            <key>ProgramArguments</key>
            <array><string>\(exe)</string></array>
            <key>RunAtLoad</key><true/>
            <key>ProcessType</key><string>Interactive</string>
            <key>StandardOutPath</key><string>/dev/null</string>
            <key>StandardErrorPath</key><string>/dev/null</string>
        </dict>
        </plist>
        """
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    static func disable() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}

// MARK: - 外部命令
struct CmdResult {
    var status: Int32
    var out: String
    var err: String
}

func runCmd(_ path: String, _ args: [String]) -> CmdResult {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe
    do {
        try task.run()
    } catch {
        return CmdResult(status: -1, out: "", err: error.localizedDescription)
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return CmdResult(status: task.terminationStatus,
                     out: String(data: outData, encoding: .utf8) ?? "",
                     err: String(data: errData, encoding: .utf8) ?? "")
}

// MARK: - 盒盖不休眠
//
// 为什么不用 caffeinate / IOPMAssertion：
// Apple 在 IOPMLib.h 里写得很清楚，kIOPMAssertPreventUserIdleSystemSleep
// 「may still sleep for lid close, Apple menu, low battery」——用户态断言
// 只挡得住空闲休眠，挡不住硬件盒盖事件。KeepingYouAwake 这类包装 caffeinate
// 的 App 因此明确声明不支持盒盖。
//
// 真正能挡住盒盖的是内核的 SleepDisabled 标志，也就是 pmset -a disablesleep。
// 它在 Apple Silicon 上原生生效，盒盖、电池供电都能挡住。代价是需要 root，
// 所以这里提供两种授权方式：装一条精确 sudoers 规则（免密码），或走系统授权弹窗。
enum LidGuard {
    static let pmset = "/usr/bin/pmset"
    static let sudoersFile = "/etc/sudoers.d/macpowertemp"
    static let helperPath = "/Library/PrivilegedHelperTools/com.workbuddy.macpowertemp.ctl"

    /// 系统当前是否禁用了休眠。优先直接读取 IORegistry IOPMrootDomain.SleepDisabled，
    /// 不可用时再回落到 `pmset -g`。
    static func isSleepDisabled() -> Bool {
        let fast = sensors_sleep_disabled()
        if fast >= 0 { return fast == 1 }
        let r = runCmd(pmset, ["-g"])
        for raw in r.out.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("SleepDisabled") else { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            return parts.last == "1"
        }
        return false
    }

    static var hasPasswordlessRule: Bool {
        FileManager.default.fileExists(atPath: sudoersFile)
    }

    static var hasFullPasswordlessRule: Bool {
        hasPasswordlessRule && FileManager.default.fileExists(atPath: helperPath)
    }

    /// 切换盒盖不休眠。可能弹出系统授权窗口，请在后台线程调用。
    @discardableResult
    static func setSleepDisabled(_ on: Bool) -> (ok: Bool, message: String) {
        let value = on ? "1" : "0"
        let args = ["-a", "disablesleep", value]

        // 先试免密码路径；失败不直接报错，继续回落到授权弹窗，
        // 这样即使 /etc/sudoers.d 未被主配置引入也照样能切换
        if hasPasswordlessRule {
            let r = runCmd("/usr/bin/sudo", ["-n", pmset] + args)
            if r.status == 0 { return (true, "") }
        }

        let full = ([pmset] + args).joined(separator: " ")
        let script = "do shell script \"\(full)\" with administrator privileges"
        let r = runCmd("/usr/bin/osascript", ["-e", script])
        if r.status == 0 { return (true, "") }
        if r.err.contains("-128") { return (false, "已取消授权") }
        return (false, r.err.isEmpty ? "授权失败（状态 \(r.status)）" : r.err)
    }

    /// 精确的 sudoers 规则内容。sudoers 按字面匹配、不支持通配符，
    /// 仅授权盒盖不休眠开关与 root 属主的控制助手。
    static func sudoersRule() -> String {
        let user = NSUserName()
        return "\(user) ALL = (root) NOPASSWD: \(pmset) -a disablesleep 0, \(pmset) -a disablesleep 1, \(helperPath)\n"
    }

    static func installPasswordless() -> (ok: Bool, message: String) {
        guard let bundledHelper = PowerCapGuard.bundledHelperPath,
              FileManager.default.fileExists(atPath: bundledHelper) else {
            return (false, "未找到内置 powerctl 助手程序")
        }
        let tmp = "/tmp/macpowertemp-sudoers-\(getpid())"
        do {
            try sudoersRule().write(toFile: tmp, atomically: true, encoding: .utf8)
        } catch {
            return (false, "写入临时文件失败：\(error.localizedDescription)")
        }
        let escapedHelper = bundledHelper.replacingOccurrences(of: "'", with: "'\\''")
        // 安装 root 属主的 powerctl 并校验 sudoers 语法
        let sh = "install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools && "
               + "install -o root -g wheel -m 0755 '\(escapedHelper)' '\(helperPath)' && "
               + "visudo -cf '\(tmp)' >/dev/null 2>&1 && "
               + "install -o root -g wheel -m 0440 '\(tmp)' '\(sudoersFile)' && "
               + "visudo -cf '\(sudoersFile)' >/dev/null 2>&1; rm -f '\(tmp)'"
        let script = "do shell script \"\(sh)\" with administrator privileges"
        let r = runCmd("/usr/bin/osascript", ["-e", script])
        if r.status == 0 && hasFullPasswordlessRule { return (true, "") }
        if r.err.contains("-128") { return (false, "已取消授权") }
        return (false, r.err.isEmpty ? "安装失败（状态 \(r.status)）" : r.err)
    }

    static func removePasswordless() -> (ok: Bool, message: String) {
        let script = "do shell script \"rm -f '\(sudoersFile)' '\(helperPath)'\" with administrator privileges"
        let r = runCmd("/usr/bin/osascript", ["-e", script])
        if r.status == 0 && !hasPasswordlessRule { return (true, "") }
        if r.err.contains("-128") { return (false, "已取消授权") }
        return (false, r.err.isEmpty ? "移除失败（状态 \(r.status)）" : r.err)
    }
}

// MARK: - 功率限制与超省电控制
enum PowerCapGuard {
    static let ultraPkgWatts: Double = 2.0
    static let ultraGpuMw: Int64 = 2000

    private static let kUltraActive = "ultraModeActive"
    private static let kOrigGpuMw   = "origGpuMaxMw"
    private static let kOrigLpmBatt = "origLpmBatt"
    private static let kOrigLpmAC   = "origLpmAC"

    static var bundledHelperPath: String? {
        if let p = Bundle.main.resourceURL?.appendingPathComponent("powerctl").path,
           FileManager.default.fileExists(atPath: p) {
            return p
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let local = exeDir.appendingPathComponent("powerctl").path
        return FileManager.default.fileExists(atPath: local) ? local : nil
    }

    static func readLowPowerModes() -> (battery: Int, ac: Int) {
        let r = runCmd(LidGuard.pmset, ["-g", "custom"])
        var batt = 0, ac = 0
        var section = ""
        for raw in r.out.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Battery Power") { section = "batt"; continue }
            if line.hasPrefix("AC Power") { section = "ac"; continue }
            if line.hasPrefix("lowpowermode") {
                let val = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1" ? 1 : 0
                if section == "batt" { batt = val }
                else if section == "ac" { ac = val }
            }
        }
        return (batt, ac)
    }

    static func currentSystemLowPowerMode(onAC: Bool) -> Bool {
        let m = readLowPowerModes()
        return (onAC ? m.ac : m.battery) == 1
    }

    static var isUltraActive: Bool {
        let flag = UserDefaults.standard.bool(forKey: kUltraActive)
        if !flag { return false }
        let cap = sensors_pkg_power_cap_w()
        if cap < 0 {
            // 外部已解除封顶时自动同步状态
            UserDefaults.standard.set(false, forKey: kUltraActive)
            return false
        }
        return true
    }

    private static func snapshotOriginalIfNeeded() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: kOrigGpuMw) == nil {
            let gm = sensors_gpu_power_cap_mw()
            if gm >= 4000 {
                defaults.set(Int(gm), forKey: kOrigGpuMw)
            } else {
                defaults.set(24240, forKey: kOrigGpuMw)
            }
        }
        if !defaults.bool(forKey: kUltraActive) {
            let lpm = readLowPowerModes()
            defaults.set(lpm.battery, forKey: kOrigLpmBatt)
            defaults.set(lpm.ac, forKey: kOrigLpmAC)
        }
    }

    @discardableResult
    private static func runPowerctl(_ args: [String]) -> (ok: Bool, message: String) {
        if LidGuard.hasFullPasswordlessRule {
            let r = runCmd("/usr/bin/sudo", ["-n", LidGuard.helperPath] + args)
            if r.status == 0 { return (true, "") }
        }
        guard let helper = bundledHelperPath else {
            return (false, "未找到 powerctl 程序")
        }
        let escaped = helper.replacingOccurrences(of: "'", with: "'\\''")
        let argStr = args.map { "'\($0)'" }.joined(separator: " ")
        let script = "do shell script \"'\(escaped)' \(argStr)\" with administrator privileges"
        let r = runCmd("/usr/bin/osascript", ["-e", script])
        if r.status == 0 { return (true, "") }
        if r.err.contains("-128") { return (false, "已取消授权") }
        return (false, r.err.isEmpty ? "执行失败（状态 \(r.status)）" : r.err)
    }

    @discardableResult
    static func applyPackageCap(_ watts: Double) -> (ok: Bool, message: String) {
        let clamped = min(60.0, max(1.0, watts))
        snapshotOriginalIfNeeded()
        // 若此前开启过超省电模式，先恢复 GPU 与系统省电模式，再应用指定封装瓦数
        if UserDefaults.standard.bool(forKey: kUltraActive) {
            _ = restoreAll()
        }
        let wStr = String(format: "%.2f", clamped)
        let res = runPowerctl(["cap", wStr])
        if res.ok {
            UserDefaults.standard.set(clamped, forKey: "lastTargetWatts")
        }
        return res
    }

    @discardableResult
    static func enableUltra() -> (ok: Bool, message: String) {
        snapshotOriginalIfNeeded()
        let res = runPowerctl(["ultra", String(format: "%.1f", ultraPkgWatts), "\(ultraGpuMw)"])
        if res.ok {
            UserDefaults.standard.set(true, forKey: kUltraActive)
        }
        return res
    }

    @discardableResult
    static func restoreAll() -> (ok: Bool, message: String) {
        let defaults = UserDefaults.standard
        let origGpu = defaults.object(forKey: kOrigGpuMw) as? Int ?? 24240
        var args = ["restore", "\(origGpu)"]
        if let b = defaults.object(forKey: kOrigLpmBatt) as? Int,
           let c = defaults.object(forKey: kOrigLpmAC) as? Int {
            args.append("\(b)")
            args.append("\(c)")
        }
        let res = runPowerctl(args)
        if res.ok {
            defaults.set(false, forKey: kUltraActive)
            defaults.removeObject(forKey: kOrigLpmBatt)
            defaults.removeObject(forKey: kOrigLpmAC)
        }
        return res
    }
}

// MARK: - 菜单内嵌功率控制面板
final class PowerControlView: NSView {
    private let card = NSView()
    private let titleLabel = NSTextField(labelWithString: "芯片目标")
    private let subLabel = NSTextField(labelWithString: "SoC 封装")
    private let statusBadge = NSTextField(labelWithString: "未设目标")

    private let presets: [Double] = [8, 10, 12, 15, 20]
    private var presetButtons: [NSButton] = []

    private let slider = NSSlider(value: 15.0, minValue: 1.0, maxValue: 25.0, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "15.0 W")
    private let applyButton = NSButton(title: "应用", target: nil, action: nil)

    private let ultraButton = NSButton(title: "超省电 (2W)", target: nil, action: nil)
    private let restoreButton = NSButton(title: "一键恢复", target: nil, action: nil)
    private let footerLabel = NSTextField(labelWithString: "芯片目标不等于整机功耗上限")

    var targetWatts: Double = 15.0
    private var currentCapW: Double? = nil
    private var ultraActive: Bool = false
    private var busy: Bool = false

    var onApplyWatts: ((Double) -> Void)?
    var onToggleUltra: (() -> Void)?
    var onRestore: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 304, height: 192))
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func stylePillButton(_ btn: NSButton, fontSize: CGFloat, weight: NSFont.Weight = .medium) {
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 6
        btn.font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        btn.alignment = .center
    }

    private func setupUI() {
        wantsLayer = true

        card.frame = NSRect(x: 10, y: 4, width: 284, height: 184)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 0.75
        addSubview(card)

        // Header
        titleLabel.frame = NSRect(x: 12, y: 153, width: 88, height: 18)
        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .labelColor
        card.addSubview(titleLabel)

        subLabel.frame = NSRect(x: 98, y: 154, width: 64, height: 15)
        subLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        subLabel.textColor = .tertiaryLabelColor
        card.addSubview(subLabel)

        statusBadge.frame = NSRect(x: 176, y: 152, width: 96, height: 19)
        statusBadge.alignment = .center
        statusBadge.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = 6
        card.addSubview(statusBadge)

        // Preset buttons
        let pw: CGFloat = 48
        let gap: CGFloat = 5
        let startX: CGFloat = 12
        for (idx, w) in presets.enumerated() {
            let b = NSButton(title: "\(Int(w))W", target: self, action: #selector(presetTapped(_:)))
            b.tag = idx
            b.frame = NSRect(x: startX + CGFloat(idx) * (pw + gap), y: 121, width: pw, height: 22)
            stylePillButton(b, fontSize: 11, weight: .semibold)
            card.addSubview(b)
            presetButtons.append(b)
        }

        // Slider + read-only value + apply button
        slider.frame = NSRect(x: 11, y: 90, width: 148, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        card.addSubview(slider)

        valueLabel.frame = NSRect(x: 164, y: 92, width: 60, height: 16)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        valueLabel.alignment = .center
        valueLabel.toolTip = "拖动滑条设置芯片目标（1.0 – 25.0 W，步进 0.5 W）"
        card.addSubview(valueLabel)

        applyButton.frame = NSRect(x: 228, y: 89, width: 44, height: 22)
        stylePillButton(applyButton, fontSize: 11, weight: .semibold)
        applyButton.target = self
        applyButton.action = #selector(applyTapped)
        card.addSubview(applyButton)

        // Ultra Low Power Mode + One-Click Restore
        ultraButton.frame = NSRect(x: 12, y: 46, width: 146, height: 30)
        stylePillButton(ultraButton, fontSize: 12, weight: .semibold)
        ultraButton.layer?.cornerRadius = 7
        ultraButton.toolTip = "设置芯片目标 2.0W、GPU 上限 2.0W 并开启系统省电；不是整机功耗上限"
        ultraButton.target = self
        ultraButton.action = #selector(ultraTapped)
        card.addSubview(ultraButton)

        restoreButton.frame = NSRect(x: 164, y: 46, width: 108, height: 30)
        stylePillButton(restoreButton, fontSize: 12, weight: .semibold)
        restoreButton.layer?.cornerRadius = 7
        restoreButton.toolTip = "清除芯片目标并恢复原厂 GPU 上限与省电模式设置"
        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)
        card.addSubview(restoreButton)

        // Footer
        footerLabel.frame = NSRect(x: 12, y: 8, width: 260, height: 30)
        footerLabel.font = NSFont.systemFont(ofSize: 10.0)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.cell?.usesSingleLineMode = false
        footerLabel.cell?.wraps = true
        footerLabel.lineBreakMode = .byWordWrapping
        footerLabel.maximumNumberOfLines = 2
        card.addSubview(footerLabel)

        refreshThemeAndState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshThemeAndState()
    }

    func update(currentCapW: Double?, gpuCapMW: Int64?, ultraActive: Bool, sysLpmOn: Bool, busy: Bool) {
        let prevCap = self.currentCapW
        self.currentCapW = currentCapW
        self.ultraActive = ultraActive
        self.busy = busy

        if let cap = currentCapW, !ultraActive, abs((prevCap ?? -1) - cap) >= 0.05 {
            // 硬件上限实际变化时同步滑块，不打断用户正在调整中的目标值
            if NSApp.currentEvent?.type != .leftMouseDragged {
                targetWatts = cap
            }
        } else if currentCapW == nil && targetWatts < 1.0 {
            let saved = UserDefaults.standard.double(forKey: "lastTargetWatts")
            targetWatts = saved >= 1.0 ? saved : 15.0
        }

        slider.doubleValue = min(25.0, max(1.0, targetWatts))
        valueLabel.stringValue = String(format: "%.1fW", targetWatts)

        let gpuStr = gpuCapMW.map { String(format: "%.1fW", Double($0) / 1000.0) } ?? "—"
        let lpmStr = sysLpmOn ? "开" : "关"
        footerLabel.stringValue = "GPU 上限 \(gpuStr) · 系统省电 \(lpmStr)\n芯片目标不等于整机功耗上限"

        refreshThemeAndState()
    }

    private func refreshThemeAndState() {
        card.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.055).cgColor
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

        // Badge
        if busy {
            statusBadge.stringValue = "应用中…"
            statusBadge.textColor = .white
            statusBadge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        } else if ultraActive {
            statusBadge.stringValue = "芯片目标 2.0W"
            statusBadge.textColor = .white
            statusBadge.layer?.backgroundColor = NSColor.systemTeal.cgColor
        } else if let cap = currentCapW {
            statusBadge.stringValue = String(format: "芯片目标 %.1fW", cap)
            statusBadge.textColor = .black
            statusBadge.layer?.backgroundColor = StatusImage.amber.cgColor
        } else {
            statusBadge.stringValue = "未设目标"
            statusBadge.textColor = .secondaryLabelColor
            statusBadge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }

        // Presets
        for (idx, b) in presetButtons.enumerated() {
            let w = presets[idx]
            let isSelected = !ultraActive && currentCapW != nil && abs((currentCapW ?? 0) - w) < 0.15
            let isTarget = abs(targetWatts - w) < 0.15
            if isSelected {
                b.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                b.contentTintColor = .white
                b.attributedTitle = NSAttributedString(
                    string: "\(Int(w))W",
                    attributes: [.font: b.font!, .foregroundColor: NSColor.white])
            } else if isTarget {
                b.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                b.attributedTitle = NSAttributedString(
                    string: "\(Int(w))W",
                    attributes: [.font: b.font!, .foregroundColor: NSColor.controlAccentColor])
            } else {
                b.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
                b.attributedTitle = NSAttributedString(
                    string: "\(Int(w))W",
                    attributes: [.font: b.font!, .foregroundColor: NSColor.labelColor])
            }
        }

        valueLabel.stringValue = String(format: "%.1fW", targetWatts)
        valueLabel.textColor = .labelColor

        // Apply button
        let pendingDiff = currentCapW == nil || abs((currentCapW ?? -1) - targetWatts) >= 0.05 || ultraActive
        let applyBg = pendingDiff ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.08)
        let applyFg = pendingDiff ? NSColor.white : NSColor.secondaryLabelColor
        applyButton.layer?.backgroundColor = applyBg.cgColor
        applyButton.attributedTitle = NSAttributedString(
            string: "应用",
            attributes: [.font: applyButton.font!, .foregroundColor: applyFg])
        applyButton.isEnabled = !busy

        // Ultra button
        if ultraActive {
            ultraButton.layer?.backgroundColor = NSColor.systemTeal.cgColor
            ultraButton.attributedTitle = NSAttributedString(
                string: "✓ 超省电已开启",
                attributes: [.font: ultraButton.font!, .foregroundColor: NSColor.white])
        } else {
            ultraButton.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.16).cgColor
            ultraButton.attributedTitle = NSAttributedString(
                string: "✦ 超省电模式 (2W)",
                attributes: [.font: ultraButton.font!, .foregroundColor: NSColor.systemTeal])
        }
        ultraButton.isEnabled = !busy

        // Restore button
        let isCapped = (currentCapW != nil) || ultraActive
        restoreButton.isEnabled = isCapped && !busy
        if isCapped {
            restoreButton.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.18).cgColor
            restoreButton.attributedTitle = NSAttributedString(
                string: "↺ 一键恢复",
                attributes: [.font: restoreButton.font!, .foregroundColor: NSColor.systemOrange])
        } else {
            restoreButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            restoreButton.attributedTitle = NSAttributedString(
                string: "↺ 已为原厂",
                attributes: [.font: restoreButton.font!, .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }

    @objc private func presetTapped(_ sender: NSButton) {
        let w = presets[sender.tag]
        targetWatts = w
        slider.doubleValue = w
        refreshThemeAndState()
        onApplyWatts?(w)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let snapped = (sender.doubleValue * 2.0).rounded() / 2.0
        sender.doubleValue = snapped
        targetWatts = snapped
        refreshThemeAndState()
        if NSApp.currentEvent?.type == .leftMouseUp && LidGuard.hasFullPasswordlessRule {
            onApplyWatts?(snapped)
        }
    }

    @objc private func applyTapped() {
        onApplyWatts?(targetWatts)
    }

    @objc private func ultraTapped() {
        onToggleUltra?()
    }

    @objc private func restoreTapped() {
        onRestore?()
    }
}

// MARK: - 菜单文案
enum MenuText {
    static func lines(_ r: Reading) -> [String] {
        let system = r.powerW.map { String(format: "%.2f W", $0) } ?? "不可用"
        let chip = r.chipW.map { String(format: "%.2f W", $0) } ?? "—"
        let power = system + " · 芯片当前 " + chip
        let battery: String
        if let b = r.batteryW {
            battery = String(format: "%+.2f W", b) + (b >= 0 ? "   充电" : "   放电")
        } else {
            battery = "—"
        }
        let temp = (r.tempC.map { String(format: "%.1f °C", $0) } ?? "不可用")
            + (r.tempSensor.map { "   (\($0))" } ?? "")
        let sensor = "\(r.sensorCount) 个温度传感器 · " + (r.onAC ? "适配器供电" : "电池供电")
        return ["整机功耗  " + power, "电池  " + battery, "温度  " + temp, "传感器  " + sensor]
    }
}

// MARK: - 控制器
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: DispatchSourceTimer?
    var interval: TimeInterval = 2.0

    var textSize: TextSize = {
        if let raw = UserDefaults.standard.object(forKey: "textSize") as? Int,
           let s = TextSize(rawValue: raw) { return s }
        return .large
    }()

    var colorMode: ColorMode = {
        if let raw = UserDefaults.standard.object(forKey: "colorMode") as? Int,
           let m = ColorMode(rawValue: raw) { return m }
        return .mono
    }()

    var latest = Reading()
    let chipPowerSampler = MenuChipPowerSampler()
    var smoothPower: Double?
    var smoothTemp: Double?

    private struct StatusRenderKey: Equatable {
        let powerText: String
        let tempText: String
        let accentBucket: Int
        let mode: ColorMode
        let size: TextSize
        let badge: String
        let powerBadge: String
    }
    private var lastStatusRenderKey: StatusRenderKey?
    private var lastStatusToolTip: String?

    let infoPower = NSMenuItem(title: "整机功耗 —", action: nil, keyEquivalent: "")
    let infoBattery = NSMenuItem(title: "电池 —", action: nil, keyEquivalent: "")
    let infoTemp = NSMenuItem(title: "温度 —", action: nil, keyEquivalent: "")
    let infoSensor = NSMenuItem(title: "传感器 —", action: nil, keyEquivalent: "")

    let powerControlView = PowerControlView()
    let powerControlItem = NSMenuItem()
    var powerBusy = false

    let sidecarController = SidecarController()
    let sidecarControlView = SidecarControlView()
    let sidecarControlItem = NSMenuItem()
    let sidecarHotKeyItem = NSMenuItem(title: "随航快捷键 (Ctrl+Opt+V)", action: #selector(toggleSidecarHotKey), keyEquivalent: "")

    var sizeItems: [NSMenuItem] = []
    var modeItems: [NSMenuItem] = []
    var speedItems: [NSMenuItem] = []
    let loginItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin), keyEquivalent: "")

    // 盒盖不休眠
    let lidItem = NSMenuItem(title: "盒盖不休眠", action: #selector(toggleLid), keyEquivalent: "")
    let lidStateItem = NSMenuItem(title: "休眠状态 —", action: nil, keyEquivalent: "")
    let lidPassItem = NSMenuItem(title: "免密码授权（含功率调节）", action: #selector(togglePasswordless), keyEquivalent: "")
    var sleepDisabled = false
    var lastSleepCheck = Date.distantPast

    func ema(_ prev: Double?, _ next: Double?, _ alpha: Double) -> Double? {
        guard let n = next else { return prev }
        guard let p = prev else { return n }
        return p + alpha * (n - p)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly

        sidecarController.onStateChanged = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.syncSidecarUI()
                let tip = self.buildStatusToolTip(for: self.latest)
                if tip != self.lastStatusToolTip {
                    self.lastStatusToolTip = tip
                    self.statusItem?.button?.toolTip = tip
                }
            }
        }
        sidecarController.startLifecycleHooks()

        statusItem.menu = buildMenu()
        syncChecks()

        startTimer()
        refresh()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        infoPower.toolTip = "整机：系统总功耗；芯片当前：SMC 芯片封装功耗读数。芯片读数仅在菜单展开时刷新，不是设置目标，也不是 CPU/GPU/ANE 功耗之和。"
        for item in [infoPower, infoBattery, infoTemp, infoSensor] { item.isEnabled = true }
        menu.addItem(infoPower)
        menu.addItem(infoBattery)
        menu.addItem(infoTemp)
        menu.addItem(infoSensor)
        menu.addItem(.separator())

        // 功率上限控制 & 超省电模式
        powerControlItem.title = "芯片目标控制面板"
        if let savedW = UserDefaults.standard.object(forKey: "lastTargetWatts") as? Double, savedW >= 1.0 {
            powerControlView.targetWatts = savedW
        }
        powerControlView.onApplyWatts = { [weak self] w in
            self?.runPowerAction { PowerCapGuard.applyPackageCap(w) }
        }
        powerControlView.onToggleUltra = { [weak self] in
            guard let self = self else { return }
            let rawCap = sensors_pkg_power_cap_w()
            let ultraOn = PowerCapGuard.isUltraActive && rawCap > 0 && rawCap <= 2.5
            self.runPowerAction {
                ultraOn ? PowerCapGuard.restoreAll() : PowerCapGuard.enableUltra()
            }
        }
        powerControlView.onRestore = { [weak self] in
            self?.runPowerAction { PowerCapGuard.restoreAll() }
        }
        powerControlItem.view = powerControlView
        menu.addItem(powerControlItem)
        menu.addItem(.separator())

        // 随航竖屏控制面板
        sidecarControlItem.title = "随航竖屏控制面板"
        wireSidecarControlView()
        sidecarControlItem.view = sidecarControlView
        menu.addItem(sidecarControlItem)
        menu.addItem(.separator())

        // 盒盖不休眠
        lidItem.target = self
        menu.addItem(lidItem)
        lidStateItem.isEnabled = false
        menu.addItem(lidStateItem)
        lidPassItem.target = self
        menu.addItem(lidPassItem)
        menu.addItem(.separator())

        // 字号
        let sizeMenu = NSMenu()
        for s in TextSize.allCases {
            let mi = NSMenuItem(title: s.title, action: #selector(setSize(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = s.rawValue
            sizeMenu.addItem(mi)
            sizeItems.append(mi)
        }
        let sizeItem = NSMenuItem(title: "字号", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        // 配色
        let modeMenu = NSMenu()
        for m in [ColorMode.mono, ColorMode.warmText, ColorMode.chip] {
            let mi = NSMenuItem(title: m.title, action: #selector(setMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = m.rawValue
            modeMenu.addItem(mi)
            modeItems.append(mi)
        }
        let modeItem = NSMenuItem(title: "配色", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        // 刷新频率
        let speedMenu = NSMenu()
        for (title, sec) in [("1 秒", 1.0), ("2 秒", 2.0), ("5 秒", 5.0)] {
            let mi = NSMenuItem(title: title, action: #selector(setSpeed(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = sec
            speedMenu.addItem(mi)
            speedItems.append(mi)
        }
        let speedItem = NSMenuItem(title: "刷新频率", action: nil, keyEquivalent: "")
        speedItem.submenu = speedMenu
        menu.addItem(speedItem)

        loginItem.target = self
        menu.addItem(loginItem)

        sidecarHotKeyItem.target = self
        menu.addItem(sidecarHotKeyItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 MacPowerTemp",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    func syncChecks() {
        for mi in sizeItems { mi.state = (mi.tag == textSize.rawValue) ? .on : .off }
        for mi in modeItems { mi.state = (mi.tag == colorMode.rawValue) ? .on : .off }
        for mi in speedItems {
            let sec = mi.representedObject as? TimeInterval ?? 0
            mi.state = (abs(sec - interval) < 0.01) ? .on : .off
        }
        loginItem.state = LoginItem.isEnabled ? .on : .off

        sleepDisabled = LidGuard.isSleepDisabled()
        lidItem.state = sleepDisabled ? .on : .off
        let fullAuth = LidGuard.hasFullPasswordlessRule
        lidPassItem.state = fullAuth ? .on : .off
        lidPassItem.title = (!fullAuth && LidGuard.hasPasswordlessRule)
            ? "升级免密码授权（含功率调节）"
            : "免密码授权（含功率调节）"
        lidStateItem.title = sleepDisabled
            ? "休眠已禁用 · 合盖继续运行"
            : "休眠正常 · 合盖即休眠"

        let rawCap = sensors_pkg_power_cap_w()
        let capW: Double? = rawCap > 0 ? rawCap : nil
        let rawGpu = sensors_gpu_power_cap_mw()
        let gpuMW: Int64? = rawGpu > 0 ? rawGpu : nil
        let ultraOn = PowerCapGuard.isUltraActive && (capW != nil && capW! <= 2.5)
        let sysLpm = PowerCapGuard.currentSystemLowPowerMode(onAC: latest.onAC)
        powerControlView.update(currentCapW: capW, gpuCapMW: gpuMW,
                                ultraActive: ultraOn, sysLpmOn: sysLpm, busy: powerBusy)
        sidecarHotKeyItem.state = sidecarController.hotkeyEnabled ? .on : .off
        syncSidecarUI()
    }

    func wireSidecarControlView() {
        sidecarControlView.onConnectHorizontal = { [weak self] in
            self?.sidecarController.connectHorizontal()
        }
        sidecarControlView.onToggleVertical = { [weak self] in
            self?.sidecarController.toggle()
        }
        sidecarControlView.onFlip180 = { [weak self] in
            self?.sidecarController.flip180()
        }
        sidecarControlView.onSelectResolution = { [weak self] idx in
            self?.sidecarController.selectResolution(index: idx)
        }
        sidecarControlView.onTogglePlacement = { [weak self] in
            self?.sidecarController.togglePlacementSide()
        }
        sidecarControlView.onToggleCursorGuard = { [weak self] in
            self?.sidecarController.cursorGuardEnabled.toggle()
        }
        sidecarControlView.onDisconnectSidecar = { [weak self] in
            self?.sidecarController.disconnectSidecar()
        }
        sidecarControlView.onToggleHotkey = { [weak self] in
            self?.toggleSidecarHotKey()
        }
        sidecarControlView.onRequestPermission = { [weak self] in
            self?.sidecarController.requestScreenCapturePermission()
        }
        sidecarControlView.onRequestAccessibility = { [weak self] in
            self?.sidecarController.requestAccessibilityPermission()
        }
    }

    func syncSidecarUI() {
        let metrics = sidecarController.currentMetrics()
        let deviceName = metrics?.deviceName ?? SidecarBridge.availableDeviceName()
        sidecarControlView.update(SidecarControlView.ViewState(
            isVertical: sidecarController.isVertical,
            transitionState: sidecarController.transitionState,
            hasSidecar: metrics != nil,
            hasPermission: sidecarController.hasScreenCapturePermission,
            hasAccessibilityPermission: sidecarController.hasAccessibilityPermission,
            isTouchRemappingActive: sidecarController.isTouchRemappingActive,
            deviceName: deviceName,
            activeSummary: sidecarController.activeDisplaySummary(),
            statusText: sidecarController.statusText,
            presets: sidecarController.currentPresets(),
            resolutionIndex: sidecarController.resolutionIndex,
            rotationDegrees: sidecarController.rotationDegrees,
            placeOnLeft: sidecarController.placeOnLeft,
            cursorGuardEnabled: sidecarController.cursorGuardEnabled,
            hotkeyEnabled: sidecarController.hotkeyEnabled
        ))
    }

    func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let leeway = DispatchTimeInterval.milliseconds(max(100, Int(interval * 150)))
        t.schedule(deadline: .now() + 0.1, repeating: interval, leeway: leeway)
        t.setEventHandler { [weak self] in
            let r = takeSample()
            DispatchQueue.main.async { self?.apply(r) }
        }
        t.resume()
        timer = t
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = takeSample()
            DispatchQueue.main.async { self?.apply(r) }
        }
    }

    /// 休眠状态可能被别的程序（AI 工具、终端手输 pmset）改掉，隔几秒回读一次，
    /// 保证温度后面那个符号不会说谎。
    func pollSleepStateIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastSleepCheck) > 5 else { return }
        lastSleepCheck = now
        let sd = LidGuard.isSleepDisabled()
        if sd != sleepDisabled {
            sleepDisabled = sd
            syncChecks()
            apply(latest)
        }
    }

    func buildStatusToolTip(for r: Reading) -> String {
        let capW = r.pkgCapW
        let ultraOn = PowerCapGuard.isUltraActive && (capW != nil && capW! <= 2.5)
        let pText = StatusImage.powerText(smoothPower ?? r.powerW)
        let tText = StatusImage.tempText(smoothTemp ?? r.tempC)
        let badge = StatusImage.sleepBadge(sleepDisabled: sleepDisabled)
        var tip = "整机功耗 \(pText) · 温度 \(tText)C"
        if ultraOn {
            tip += "\n✧ 超省电模式 (芯片目标 2.0W · GPU 上限 2.0W)"
        } else if let c = capW {
            tip += String(format: "\n↓ 芯片目标 %.1fW（非整机功耗上限）", c)
        }
        tip += sleepDisabled ? "\n\(badge) 休眠已禁用 · 合盖继续运行"
                             : "\n\(badge) 休眠正常 · 合盖即休眠"
        if let vSummary = sidecarController.activeDisplaySummary() {
            tip += "\n▯ 随航竖屏 \(vSummary)"
        }
        return tip
    }

    func apply(_ r: Reading) {
        pollSleepStateIfNeeded()
        var r = r
        r.chipW = chipPowerSampler.sample()
        latest = r
        smoothPower = ema(smoothPower, r.powerW, 0.3)
        smoothTemp = ema(smoothTemp, r.tempC, 0.5)

        let capW = r.pkgCapW
        let ultraOn = PowerCapGuard.isUltraActive && (capW != nil && capW! <= 2.5)
        let pText = StatusImage.powerText(smoothPower)
        let tText = StatusImage.tempText(smoothTemp)
        let badge = StatusImage.sleepBadge(sleepDisabled: sleepDisabled)
        let pBadge = StatusImage.capBadge(pkgCapW: capW, ultra: ultraOn)
        let accentBucket = (colorMode == .mono)
            ? 0
            : ((smoothTemp ?? 0) >= 85 ? 2 : ((smoothTemp ?? 0) >= 70 ? 1 : 0))
        let renderKey = StatusRenderKey(
            powerText: pText,
            tempText: tText,
            accentBucket: accentBucket,
            mode: colorMode,
            size: textSize,
            badge: badge,
            powerBadge: pBadge
        )
        if renderKey != lastStatusRenderKey {
            lastStatusRenderKey = renderKey
            statusItem.button?.image = StatusImage.render(power: pText, temp: tText,
                                                         mode: colorMode, tempC: smoothTemp,
                                                         size: textSize, badge: badge,
                                                         powerBadge: pBadge)
        }
        let tip = buildStatusToolTip(for: r)
        if tip != lastStatusToolTip {
            lastStatusToolTip = tip
            statusItem.button?.toolTip = tip
        }

        // 菜单未展开时不刷新隐藏菜单项，也避免每 2 秒拉起 pmset 子进程查询省电模式
        guard chipPowerSampler.isOpen else { return }

        let lines = MenuText.lines(r)
        infoPower.title = lines[0]
        infoBattery.title = lines[1]
        infoTemp.title = lines[2]
        infoSensor.title = lines[3]

        let sysLpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        powerControlView.update(currentCapW: capW, gpuCapMW: r.gpuCapMW,
                                ultraActive: ultraOn, sysLpmOn: sysLpm, busy: powerBusy)
    }

    // MARK: - 功率上限与超省电控制

    func runPowerAction(_ work: @escaping () -> (ok: Bool, message: String)) {
        guard !powerBusy else { return }
        powerBusy = true
        syncChecks()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = work()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.powerBusy = false
                if !res.ok && !res.message.contains("取消") {
                    let a = NSAlert()
                    a.alertStyle = .warning
                    a.messageText = "功率调节失败"
                    a.informativeText = res.message
                    a.runModal()
                }
                self.refresh()
                self.syncChecks()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        chipPowerSampler.open()
        latest.chipW = chipPowerSampler.sample()
        let lines = MenuText.lines(latest)
        infoPower.title = lines[0]
        infoBattery.title = lines[1]
        infoTemp.title = lines[2]
        infoSensor.title = lines[3]
        sidecarController.syncTouchRemapperIfNeeded()
        syncChecks()
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        chipPowerSampler.close()
        latest.chipW = nil
        infoPower.title = MenuText.lines(latest)[0]
    }

    @objc func setSize(_ sender: NSMenuItem) {
        textSize = TextSize(rawValue: sender.tag) ?? .large
        UserDefaults.standard.set(textSize.rawValue, forKey: "textSize")
        syncChecks()
        apply(latest)
    }

    @objc func setMode(_ sender: NSMenuItem) {
        colorMode = ColorMode(rawValue: sender.tag) ?? .mono
        UserDefaults.standard.set(colorMode.rawValue, forKey: "colorMode")
        syncChecks()
        apply(latest)
    }

    @objc func setSpeed(_ sender: NSMenuItem) {
        guard let sec = sender.representedObject as? TimeInterval else { return }
        interval = sec
        syncChecks()
        startTimer()
    }

    @objc func toggleLogin() {
        if LoginItem.isEnabled { LoginItem.disable() } else { LoginItem.enable() }
        syncChecks()
    }

    @objc func toggleSidecarHotKey() {
        sidecarController.hotkeyEnabled.toggle()
        syncChecks()
    }

    // MARK: - 盒盖不休眠

    @objc func toggleLid() {
        let turnOn = !sleepDisabled

        // 首次开启给一次完整告知：这是系统级开关，有电池与发热风险
        if turnOn && !UserDefaults.standard.bool(forKey: "lidWarned") {
            let power = latest.onAC ? "当前已接电源" : "当前使用电池"
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "开启「盒盖不休眠」"
            alert.informativeText = """
            开启后合上盖子时屏幕变黑，但系统不休眠，AI 任务等会继续运行。

            请注意：
            · 这是系统级开关，会禁用全部休眠，不只是盒盖
            · 期间苹果菜单里的「睡眠」也不可用
            · 电池供电会持续耗电，合盖放在包里还会发热
            · \(power)

            建议插电使用，用完及时关掉。
            """
            alert.addButton(withTitle: "开启")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else {
                syncChecks()
                return
            }
            UserDefaults.standard.set(true, forKey: "lidWarned")
        }

        // 授权弹窗可能很久，放到后台，避免卡住菜单
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = LidGuard.setSleepDisabled(turnOn)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !result.ok && !result.message.contains("取消") {
                    let a = NSAlert()
                    a.alertStyle = .warning
                    a.messageText = "切换失败"
                    a.informativeText = result.message
                        + "\n\n也可手动执行：sudo pmset -a disablesleep \(turnOn ? "1" : "0")"
                    a.runModal()
                }
                self.syncChecks()
            }
        }
    }

    @objc func togglePasswordless() {
        let installing = !LidGuard.hasFullPasswordlessRule
        let alert = NSAlert()
        if installing {
            alert.messageText = LidGuard.hasPasswordlessRule ? "升级免密码授权？" : "安装免密码授权？"
            alert.informativeText = """
            安装后，调节功率上限、开启超省电模式与切换盒盖不休眠均不再弹密码框。现在会弹一次系统授权窗口用于安装 root 只读辅助工具与规则。

            辅助工具（仅 root 可写）：\(LidGuard.helperPath)
            授权规则（写入 \(LidGuard.sudoersFile)）：

            \(LidGuard.sudoersRule())
            sudoers 按字面路径精确匹配命令、不支持通配符，随时可在本菜单移除。
            """
            alert.addButton(withTitle: LidGuard.hasPasswordlessRule ? "升级" : "安装")
        } else {
            alert.messageText = "移除免密码授权？"
            alert.informativeText = """
            移除后，每次切换盒盖不休眠或调节功率上限都会弹出系统密码框。

            将删除 \(LidGuard.sudoersFile) 与 \(LidGuard.helperPath)
            """
            alert.addButton(withTitle: "移除")
        }
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = installing
                ? LidGuard.installPasswordless()
                : LidGuard.removePasswordless()
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !result.ok && !result.message.contains("取消") {
                    let a = NSAlert()
                    a.alertStyle = .warning
                    a.messageText = installing ? "安装失败" : "移除失败"
                    a.informativeText = result.message
                    a.runModal()
                }
                self.syncChecks()
            }
        }
    }

    /// 退出前兜底：休眠开关和 CLPC 功率上限均为系统级的，退出程序不会自动恢复
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sleepOn = LidGuard.isSleepDisabled()
        let rawCap = sensors_pkg_power_cap_w()
        let capOn = rawCap > 0 || (PowerCapGuard.isUltraActive && rawCap > 0)
        guard sleepOn || capOn else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        var parts: [String] = []
        if sleepOn { parts.append("「盒盖不休眠」仍在开启") }
        if capOn {
            parts.append(PowerCapGuard.isUltraActive && rawCap <= 2.5
                ? "「超省电模式」仍在开启"
                : String(format: "芯片目标仍设为 %.1fW", rawCap))
        }
        alert.messageText = parts.joined(separator: "，且")
        alert.informativeText = "这些调节直接作用于内核/系统电源管理，退出本程序不会自动恢复。"
        alert.addButton(withTitle: "全部恢复默认并退出")
        alert.addButton(withTitle: "保持当前设置并退出")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            var errs: [String] = []
            if sleepOn {
                let r = LidGuard.setSleepDisabled(false)
                if !r.ok && !r.message.contains("取消") { errs.append("休眠恢复失败：" + r.message) }
            }
            if capOn {
                let r = PowerCapGuard.restoreAll()
                if !r.ok && !r.message.contains("取消") { errs.append("功率恢复失败：" + r.message) }
            }
            if !errs.isEmpty {
                let e = NSAlert()
                e.alertStyle = .warning
                e.messageText = "部分设置未能恢复"
                e.informativeText = errs.joined(separator: "\n")
                e.runModal()
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sidecarController.teardownForAppExit()
    }
}

// MARK: - 调试：导出一张预览图
func dumpPreview(to path: String) {
    let bg = NSColor(calibratedWhite: 0.84, alpha: 1)
    let realBar = NSColor(srgbRed: 0.587, green: 0.648, blue: 0.704, alpha: 1) // 实测菜单栏底色 #95A5B3
    let lightBar = NSColor(calibratedWhite: 0.97, alpha: 1)

    let rowH: CGFloat = 100
    let sheetW: CGFloat = 930
    let sheetH = rowH * CGFloat(TextSize.allCases.count) + 8

    let sheet = NSImage(size: NSSize(width: sheetW, height: sheetH))
    sheet.lockFocus()
    bg.setFill()
    NSRect(x: 0, y: 0, width: sheetW, height: sheetH).fill()

    let zoom: CGFloat = 3

    for (row, size) in TextSize.allCases.enumerated() {
        let y = sheetH - rowH * CGFloat(row + 1) + 8
        let itemH = StatusImage.itemHeight

        func cell(_ bgc: NSColor, x: CGFloat, w: CGFloat, barH: CGFloat,
                  scale: CGFloat, mode: ColorMode, temp: Double,
                  sleepDisabled: Bool, powerBadge: String? = nil) {
            bgc.setFill()
            NSRect(x: x, y: y + 8, width: w, height: barH).fill()

            // 单色模式下用白色模拟系统反色效果
            let tint: NSColor? = (mode == .mono && bgc != lightBar) ? .white : nil
            let img = StatusImage.render(power: "8.6W",
                                         temp: StatusImage.tempText(temp),
                                         mode: mode, tempC: temp, size: size,
                                         badge: StatusImage.sleepBadge(sleepDisabled: sleepDisabled),
                                         powerBadge: powerBadge,
                                         monoTint: tint)
            NSGraphicsContext.current?.imageInterpolation = .none
            let iw = img.size.width * scale, ih = itemH * scale
            img.draw(in: NSRect(x: x + (w - iw) / 2, y: y + 8 + (barH - ih) / 2,
                                width: iw, height: ih))
            NSGraphicsContext.current?.imageInterpolation = .high
        }

        // 真实尺寸：可休眠 / 已禁用 / 已限功率(↓) / 超省电(✧)
        cell(lightBar, x: 10,  w: 56, barH: 34, scale: 1, mode: .mono, temp: 42, sleepDisabled: false)
        cell(realBar,  x: 72,  w: 56, barH: 34, scale: 1, mode: .mono, temp: 42, sleepDisabled: false, powerBadge: "\u{2193}")
        cell(realBar,  x: 134, w: 56, barH: 34, scale: 1, mode: .mono, temp: 42, sleepDisabled: true, powerBadge: "\u{2727}")
        cell(realBar,  x: 196, w: 56, barH: 34, scale: 1, mode: .chip, temp: 42, sleepDisabled: true, powerBadge: "\u{2193}")
        // 3x 放大
        cell(realBar, x: 262, w: 122, barH: 82, scale: zoom, mode: .mono, temp: 42, sleepDisabled: false, powerBadge: "\u{2193}")
        cell(realBar, x: 388, w: 122, barH: 82, scale: zoom, mode: .mono, temp: 42, sleepDisabled: true, powerBadge: "\u{2727}")
        cell(realBar, x: 514, w: 122, barH: 82, scale: zoom, mode: .chip, temp: 76, sleepDisabled: true, powerBadge: "\u{2193}")

        // 单色模式在系统里是模板图（只取 alpha 遮罩再上色），单独模拟一遍看真实效果
        func templateCell(_ bgc: NSColor, x: CGFloat, w: CGFloat, barH: CGFloat,
                          scale: CGFloat, temp: Double, sleepDisabled: Bool) {
            bgc.setFill()
            NSRect(x: x, y: y + 8, width: w, height: barH).fill()

            let img = StatusImage.render(power: "8.6W",
                                         temp: StatusImage.tempText(temp),
                                         mode: .mono, tempC: temp, size: size,
                                         badge: StatusImage.sleepBadge(sleepDisabled: sleepDisabled))
            let iw = img.size.width * scale, ih = itemH * scale

            // 用 alpha 遮罩填成白色 —— 这就是菜单栏对模板图做的事
            let mask = NSImage(size: NSSize(width: iw, height: ih))
            mask.lockFocus()
            img.draw(in: NSRect(x: 0, y: 0, width: iw, height: ih))
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: iw, height: ih).fill(using: .sourceAtop)
            mask.unlockFocus()

            NSGraphicsContext.current?.imageInterpolation = .none
            mask.draw(in: NSRect(x: x + (w - iw) / 2, y: y + 8 + (barH - ih) / 2,
                                 width: iw, height: ih))
            NSGraphicsContext.current?.imageInterpolation = .high
        }

        templateCell(realBar, x: 646, w: 132, barH: 82, scale: zoom, temp: 42, sleepDisabled: false)
        templateCell(realBar, x: 786, w: 132, barH: 82, scale: zoom, temp: 42, sleepDisabled: true)
    }
    sheet.unlockFocus()

    guard let tiff = sheet.tiffRepresentation,
          let bmp = NSBitmapImageRep(data: tiff),
          let png = bmp.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

func dumpCardsPreview(to path: String) {
    let presets = SidecarController().currentPresets()
    func renderColumn(appearanceName: NSAppearance.Name, bgColor: NSColor, hasSidecar: Bool, isVertical: Bool, status: String) -> NSBitmapImageRep? {
        let powerView = PowerControlView()
        powerView.update(currentCapW: 12.0, gpuCapMW: 8000, ultraActive: false, sysLpmOn: false, busy: false)

        let sidecarView = SidecarControlView()
        sidecarView.update(SidecarControlView.ViewState(
            isVertical: isVertical,
            transitionState: .idle,
            hasSidecar: hasSidecar,
            hasPermission: true,
            deviceName: "iPad Pro",
            activeSummary: isVertical ? "935×1339 HiDPI 2x" : nil,
            statusText: status,
            presets: presets,
            resolutionIndex: 1,
            rotationDegrees: 270,
            placeOnLeft: false,
            cursorGuardEnabled: true,
            hotkeyEnabled: true
        ))

        let colW: CGFloat = 316
        let colH: CGFloat = 192 + 162 + 20
        let container = NSView(frame: NSRect(x: 0, y: 0, width: colW, height: colH))
        container.wantsLayer = true
        container.layer?.backgroundColor = bgColor.cgColor

        powerView.frame.origin = NSPoint(x: 6, y: 162 + 14)
        sidecarView.frame.origin = NSPoint(x: 6, y: 6)
        container.addSubview(powerView)
        container.addSubview(sidecarView)

        let win = NSWindow(
            contentRect: container.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.appearance = NSAppearance(named: appearanceName)
        win.contentView = container
        container.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(colW * 2),
            pixelsHigh: Int(colH * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: colW, height: colH)
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep
    }

    guard let disconnectedLight = renderColumn(
              appearanceName: .aqua, bgColor: NSColor(white: 0.94, alpha: 1),
              hasSidecar: false, isVertical: false,
              status: "可直连原生横屏（零虚拟屏）或一键竖屏"),
          let horizontalLight = renderColumn(
              appearanceName: .aqua, bgColor: NSColor(white: 0.94, alpha: 1),
              hasSidecar: true, isVertical: false,
              status: "已连接横屏 · 1339×935"),
          let verticalDark = renderColumn(
              appearanceName: .darkAqua, bgColor: NSColor(white: 0.16, alpha: 1),
              hasSidecar: true, isVertical: true,
              status: "竖屏 935×1339 HiDPI 2x @ 60Hz · Ctrl+Opt+V") else {
        return
    }
    let totalW = disconnectedLight.size.width * 3
    let totalH = disconnectedLight.size.height
    let sheet = NSImage(size: NSSize(width: totalW, height: totalH))
    sheet.lockFocus()
    disconnectedLight.draw(in: NSRect(x: 0, y: 0, width: disconnectedLight.size.width, height: totalH))
    horizontalLight.draw(in: NSRect(x: disconnectedLight.size.width, y: 0, width: horizontalLight.size.width, height: totalH))
    verticalDark.draw(in: NSRect(x: disconnectedLight.size.width * 2, y: 0, width: verticalDark.size.width, height: totalH))
    sheet.unlockFocus()

    guard let tiff = sheet.tiffRepresentation,
          let bmp = NSBitmapImageRep(data: tiff),
          let png = bmp.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

// MARK: - 入口
let args = CommandLine.arguments

if args.contains("--test-chip-power") {
    var reads = 0
    var sensorValue = 1.25
    let sampler = MenuChipPowerSampler(read: { reads += 1; return sensorValue })
    precondition(sampler.sample() == nil && reads == 0)
    sampler.open()
    precondition(sampler.sample() == 1.25 && reads == 1)
    sensorValue = 2.5
    precondition(sampler.sample() == 2.5 && reads == 2)
    sampler.close()
    for _ in 0..<10 { precondition(sampler.sample() == nil) }
    precondition(reads == 2)
    sampler.open()
    sensorValue = .nan
    precondition(sampler.sample() == nil)
    sensorValue = 0
    precondition(sampler.sample() == 0)
    let line = MenuText.lines(Reading(powerW: 10, chipW: 2.5, pkgCapW: 6))[0]
    precondition(line == "整机功耗  10.00 W · 芯片当前 2.50 W")
    precondition(MenuText.lines(Reading())[0] == "整机功耗  不可用 · 芯片当前 —")
    print("PASS: closed menu performs zero chip reads; open/reopen, invalid/zero readings and labels")
    exit(0)
}

if let i = args.firstIndex(of: "--dump-image"), i + 1 < args.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    dumpPreview(to: args[i + 1])
    exit(0)
}

if let i = args.firstIndex(of: "--dump-cards"), i + 1 < args.count {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    dumpCardsPreview(to: args[i + 1])
    exit(0)
}

if args.contains("--dump-sidecar") {
    let sample = SidecarMetrics(
        displayID: 4,
        deviceName: "iPad13,4",
        landscapePoints: CGSize(width: 1339, height: 935),
        landscapePixels: CGSize(width: 2678, height: 1870),
        scale: 2.0,
        refreshRate: 60.0
    )
    let presets = sample.portraitPresets()
    assert(presets.count == 4 && presets[1].size == CGSize(width: 935, height: 1339))
    let mainRect = CGRect(x: 0, y: 0, width: 1710, height: 1112)
    let moves = sample.computeDisplayOrigins(mainBounds: mainRect, virtualID: 99, portraitSize: presets[1].size, placeOnLeft: false)
    precondition(moves[0] == (99, 1710, 0) && moves[1] == (4, -1339, -935))
    let hidden = CGRect(x: -1339, y: -935, width: 1339, height: 935)
    let virt = CGRect(x: 1710, y: 0, width: 935, height: 1339)
    // 270°: landscape top-left (u=0,v=0) -> portrait top-right (nx=1,ny=0)
    let p270 = SidecarInputTransform.mapPoint(CGPoint(x: hidden.minX, y: hidden.minY), from: hidden, to: virt, rotationDegrees: 270)
    precondition(abs(p270.x - (virt.maxX - 0.5)) < 0.01 && abs(p270.y - virt.minY) < 0.01)
    // 270°: landscape quarter (u=0.25,v=0.25) -> portrait (nx=0.75,ny=0.25)
    let q270 = SidecarInputTransform.mapPoint(CGPoint(x: hidden.minX + 1339 * 0.25, y: hidden.minY + 935 * 0.25), from: hidden, to: virt, rotationDegrees: 270)
    precondition(abs(q270.x - (virt.minX + 935 * 0.75)) < 0.01 && abs(q270.y - (virt.minY + 1339 * 0.25)) < 0.01)
    // 90°: landscape quarter (u=0.75,v=0.75) -> portrait (nx=0.75,ny=0.25)
    let q90 = SidecarInputTransform.mapPoint(CGPoint(x: hidden.minX + 1339 * 0.75, y: hidden.minY + 935 * 0.75), from: hidden, to: virt, rotationDegrees: 90)
    precondition(abs(q90.x - (virt.minX + 935 * 0.75)) < 0.01 && abs(q90.y - (virt.minY + 1339 * 0.25)) < 0.01)
    let s270 = SidecarInputTransform.rotateScrollAxes(axis1: 5, axis2: -10, rotationDegrees: 270)
    precondition(s270.axis1 == -10 && s270.axis2 == -5)
    let s90 = SidecarInputTransform.rotateScrollAxes(axis1: 5, axis2: -10, rotationDegrees: 90)
    precondition(s90.axis1 == 10 && s90.axis2 == 5)
    print("SIDECAR SELF-TEST PASS")
    print("Devices visible: \(SidecarBridge.devices().count)")
    print("ScreenRecording TCC: \(CGPreflightScreenCaptureAccess())")
    if let live = SidecarBridge.detectMetrics(excludingVirtualID: 0) {
        print("Live Sidecar: \(live.deviceName) | \(Int(live.landscapePoints.width))x\(Int(live.landscapePoints.height)) @ \(live.scale)x")
    } else {
        print("Live Sidecar: none")
    }
    exit(0)
}

if args.contains("--dump-menu") {
    let c = AppController()
    let m = c.buildMenu()
    c.syncChecks()
    func walk(_ menu: NSMenu, _ depth: Int) {
        for item in menu.items {
            let pad = String(repeating: "  ", count: depth)
            let mark = item.isSeparatorItem ? "───"
                     : (item.state == .on ? "[✓]" : "[ ]")
            print("\(pad)\(mark) \(item.title)")
            if let sub = item.submenu { walk(sub, depth + 1) }
        }
    }
    walk(m, 0)
    exit(0)
}

if args.contains("--dump-lid") {
    print("SleepDisabled  = \(LidGuard.isSleepDisabled())")
    print("免密码规则     = \(LidGuard.hasPasswordlessRule)")
    if LidGuard.hasPasswordlessRule {
        print("规则文件       = \(LidGuard.sudoersFile)")
    }
    print("sudoers 规则内容：")
    print(LidGuard.sudoersRule())
    exit(0)
}

if args.contains("--dump-readings") {
    let chipSampler = MenuChipPowerSampler()
    if args.contains("--include-chip") { chipSampler.open() }
    for i in 0..<6 {
        var r = takeSample()
        r.chipW = chipSampler.sample()
        print("[\(i)] 状态栏项：\(StatusImage.powerText(r.powerW))  /  \(StatusImage.tempText(r.tempC))")
        for line in MenuText.lines(r) { print("      " + line) }
        if i < 5 { Thread.sleep(forTimeInterval: 2.0) }
    }
    exit(0)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
