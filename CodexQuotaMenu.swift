import AppKit
import Foundation
import ServiceManagement

private var usesChinese: Bool {
    Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
}

private func tr(_ chinese: String, _ english: String) -> String {
    usesChinese ? chinese : english
}

struct QuotaWindow {
    let used: Double
    let minutes: Int
    let reset: Date
    var remaining: Double { max(0, min(100, 100 - used)) }
}

struct ProjectUsage {
    let name: String
    let tokens: Int64
}

struct Snapshot {
    var weekly: QuotaWindow?
    var projects: [ProjectUsage] = []
    var updatedAt: Date?
}

enum LocalCodexReader {
    static let roots = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions")
    ]

    static func snapshot(includeProjects: Bool = true) -> Snapshot {
        let files = logFiles()
        var result = Snapshot()

        for file in files.prefix(20) {
            guard let record = latestRecord(in: file.url) else { continue }
            if result.updatedAt == nil, let limits = record.limits {
                result.updatedAt = record.timestamp ?? file.modified
                for window in limits {
                    if window.minutes == 10_080 { result.weekly = window }
                }
                break
            }
        }

        if includeProjects {
            let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            var totals: [String: Int64] = [:]
            for file in files where file.modified >= cutoff {
                guard let record = latestRecord(in: file.url), record.tokens > 0 else { continue }
                let name = record.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "其他"
                totals[name, default: 0] += record.tokens
            }
            result.projects = totals.map(ProjectUsage.init).sorted { $0.tokens > $1.tokens }.prefix(5).map { $0 }
        }
        return result
    }

    private struct LogFile { let url: URL; let modified: Date }
    private struct Record {
        var limits: [QuotaWindow]?
        var tokens: Int64 = 0
        var cwd: String?
        var timestamp: Date?
    }

    private static func logFiles() -> [LogFile] {
        var files: [LogFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                files.append(LogFile(url: url, modified: values.contentModificationDate ?? .distantPast))
            }
        }
        return files.sorted { $0.modified > $1.modified }
    }

    private static func latestRecord(in url: URL) -> Record? {
        guard let text = tail(url, bytes: 8 * 1_024 * 1_024) else { return nil }
        var record = Record()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if record.cwd == nil,
               let type = json["type"] as? String,
               type == "turn_context",
               let payload = json["payload"] as? [String: Any] {
                record.cwd = payload["cwd"] as? String
            }

            guard record.limits == nil,
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any] else { continue }

            if let total = info["total_token_usage"] as? [String: Any] {
                record.tokens = int64(total["total_tokens"])
            }
            if let stamp = json["timestamp"] as? String {
                record.timestamp = ISO8601DateFormatter().date(from: stamp)
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                record.limits = ["primary", "secondary"].compactMap { key in
                    guard let item = limits[key] as? [String: Any],
                          let used = number(item["used_percent"]),
                          let minutes = item["window_minutes"] as? Int,
                          let reset = number(item["resets_at"]) else { return nil }
                    return QuotaWindow(used: used, minutes: minutes, reset: Date(timeIntervalSince1970: reset))
                }
            }
        }
        return record.limits == nil && record.tokens == 0 ? nil : record
    }

    private static func tail(_ url: URL, bytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > bytes ? end - bytes : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") { text.removeSubrange(...newline) }
        return text
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func int64(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }

    static func selfTest() -> Bool {
        let window = QuotaWindow(used: 31, minutes: 10_080, reset: Date(timeIntervalSince1970: 1_787_203_247))
        return window.remaining == 69 && window.minutes == 10_080
    }
}

final class BarRowView: NSView {
    init(title: String, detail: String, value: Double) {
        super.init(frame: NSRect(x: 0, y: 0, width: 310, height: 63))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.frame = NSRect(x: 14, y: 42, width: 282, height: 17)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.frame = NSRect(x: 14, y: 23, width: 282, height: 15)
        let bar = NSProgressIndicator(frame: NSRect(x: 14, y: 8, width: 282, height: 8))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        bar.doubleValue = value
        addSubview(titleLabel)
        addSubview(detailLabel)
        addSubview(bar)
    }
    required init?(coder: NSCoder) { nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var snapshot = Snapshot()
    private var lastProjectRefresh = Date.distantPast
    private var refreshTimer: Timer?
    private let defaults = UserDefaults.standard
    private let codexBundleID = "com.openai.codex"

    private var showWeekly: Bool {
        get { defaults.object(forKey: "showWeekly") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showWeekly") }
    }

    private var followCodexLaunch: Bool {
        get { defaults.bool(forKey: "followCodexLaunch") }
        set { defaults.set(newValue, forKey: "followCodexLaunch") }
    }

    private var followCodexQuit: Bool {
        get { defaults.bool(forKey: "followCodexQuit") }
        set { defaults.set(newValue, forKey: "followCodexQuit") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = tr("CodeX Usage Bar（每周剩余）", "CodeX Usage Bar (weekly remaining)")
        statusItem.button?.imagePosition = .imageLeading
        observeCodexLifecycle()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
        rebuildMenu()
        if followCodexLaunch && !isCodexRunning { statusItem.isVisible = false }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        rebuildMenu()
    }

    private func refresh() {
        let needsProjects = Date().timeIntervalSince(lastProjectRefresh) >= 60 * 60
        let fresh = LocalCodexReader.snapshot(includeProjects: needsProjects)
        if needsProjects {
            snapshot = fresh
            lastProjectRefresh = Date()
        } else {
            snapshot.weekly = fresh.weekly
            snapshot.updatedAt = fresh.updatedAt
        }
        updateTitle()
    }

    private func updateTitle() {
        statusItem.button?.title = showWeekly ? percent(snapshot.weekly) : ""
        statusItem.button?.image = quotaIcon(remaining: snapshot.weekly?.remaining)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        addHeader("CodeX Usage Bar")
        addQuota(tr("每周余量", "Weekly Remaining"), snapshot.weekly)

        menu.addItem(.separator())
        addHeader(tr("本机近 7 天项目用量", "Local Project Usage · 7 Days"))
        let total = max(1, snapshot.projects.reduce(Int64(0)) { $0 + $1.tokens })
        if snapshot.projects.isEmpty {
            addDisabled(tr("暂无本地项目数据", "No local project data"))
        } else {
            for project in snapshot.projects {
                let share = Double(project.tokens) / Double(total) * 100
                addRow(title: project.name, detail: "\(tokenText(project.tokens)) · \(Int(share.rounded()))%", value: share)
            }
        }

        menu.addItem(.separator())
        addToggle(tr("菜单栏显示每周余量", "Show weekly remaining in menu bar"), action: #selector(toggleWeekly), enabled: showWeekly)
        addToggle(tr("Codex 启动时显示 Usage Bar", "Show Usage Bar when Codex opens"), action: #selector(toggleFollowCodexLaunch), enabled: followCodexLaunch)
        addToggle(tr("Codex 退出时隐藏 Usage Bar", "Hide Usage Bar when Codex quits"), action: #selector(toggleFollowCodexQuit), enabled: followCodexQuit)
        if let updated = snapshot.updatedAt {
            addDisabled(tr("本地记录更新：", "Local record updated: ") + dateText(updated))
        } else {
            addDisabled(tr("未找到 Codex 余量记录", "No Codex usage record found"))
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: tr("退出 App", "Quit App"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addHeader(_ text: String) {
        let item = NSMenuItem()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 43, y: 8, width: 253, height: 17)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 34))
        if let icon = appIcon() {
            let imageView = NSImageView(frame: NSRect(x: 14, y: 4, width: 25, height: 25))
            imageView.image = icon
            view.addSubview(imageView)
        }
        view.addSubview(label)
        item.view = view
        menu.addItem(item)
    }

    private func addQuota(_ title: String, _ window: QuotaWindow?) {
        guard let window else {
            addRow(title: title, detail: tr("本机最新记录未返回此窗口", "Latest local record did not include this window"), value: 0)
            return
        }
        addRow(title: "\(title)  \(Int(window.remaining.rounded()))%", detail: tr("重置：", "Resets: ") + dateText(window.reset), value: window.remaining)
    }

    private func addRow(title: String, detail: String, value: Double) {
        let item = NSMenuItem()
        item.view = BarRowView(title: title, detail: detail, value: value)
        menu.addItem(item)
    }

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addToggle(_ title: String, action: Selector, enabled: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = enabled ? .on : .off
        menu.addItem(item)
    }

    private func percent(_ window: QuotaWindow?) -> String {
        window.map { "\(Int($0.remaining.rounded()))%" } ?? "--"
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = Calendar.current.isDateInToday(date)
            ? (usesChinese ? "今天 HH:mm" : "'Today' HH:mm")
            : (usesChinese ? "M月d日 HH:mm" : "MMM d HH:mm")
        return formatter.string(from: date)
    }

    private func tokenText(_ count: Int64) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM tokens", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK tokens", Double(count) / 1_000) }
        return "\(count) tokens"
    }

    @objc private func toggleWeekly() {
        showWeekly.toggle()
        updateTitle()
        rebuildMenu()
    }

    @objc private func toggleFollowCodexLaunch() {
        followCodexLaunch.toggle()
        updateLoginItem()
        statusItem.isVisible = !followCodexLaunch || isCodexRunning
        rebuildMenu()
    }

    @objc private func toggleFollowCodexQuit() {
        followCodexQuit.toggle()
        updateLoginItem()
        if !followCodexQuit { statusItem.isVisible = true }
        rebuildMenu()
    }

    private var isCodexRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleID).isEmpty
    }

    private func observeCodexLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(workspaceAppLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(workspaceAppTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        updateLoginItem()
    }

    @objc private func workspaceAppLaunched(_ notification: Notification) {
        guard followCodexLaunch, bundleID(from: notification) == codexBundleID else { return }
        statusItem.isVisible = true
        refresh()
        rebuildMenu()
    }

    @objc private func workspaceAppTerminated(_ notification: Notification) {
        guard followCodexQuit, bundleID(from: notification) == codexBundleID else { return }
        statusItem.isVisible = false
    }

    private func bundleID(from notification: Notification) -> String? {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    private func updateLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if followCodexLaunch || followCodexQuit {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            // The menu settings remain useful for the current session even if macOS declines login-item registration.
        }
    }

    private func appIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    private func quotaIcon(remaining: Double?) -> NSImage? {
        guard let source = appIcon() else { return nil }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: size))

        let center = NSPoint(x: 9, y: 9)
        let radius: CGFloat = 7
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 2
        NSColor(calibratedWhite: 0.12, alpha: 1).setStroke()
        track.stroke()

        if let remaining {
            let value = max(0, min(100, remaining))
            let used = 100 - value
            let ring = NSBezierPath()
            ring.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90 - CGFloat(used / 100 * 360),
                endAngle: -270,
                clockwise: true
            )
            ring.lineWidth = 2
            ring.lineCapStyle = .round
            NSColor(srgbRed: 0.16, green: 0.95, blue: 0.49, alpha: 1).setStroke()
            ring.stroke()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}

if CommandLine.arguments.contains("--self-test") {
    exit(LocalCodexReader.selfTest() ? 0 : 1)
}

if CommandLine.arguments.contains("--snapshot") {
    let value = LocalCodexReader.snapshot()
    print("weekly=\(value.weekly.map { Int($0.remaining) } ?? -1) projects=\(value.projects.count)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
