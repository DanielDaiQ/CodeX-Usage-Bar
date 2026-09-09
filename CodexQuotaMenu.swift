import AppKit
import Foundation
import ServiceManagement

private var usesChinese: Bool {
    Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
}

private func tr(_ chinese: String, _ english: String) -> String {
    usesChinese ? chinese : english
}

final class CodexFolderAccess {
    static let shared = CodexFolderAccess()

    private let bookmarkKey = "codexFolderBookmark"
    private var activeURL: URL?

    func currentURL() -> URL? {
        if let activeURL { return activeURL }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            // The locally built app is not sandboxed, so it can read the local
            // Codex folder without repeatedly asking for folder permission.
            let localCodex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil,
               FileManager.default.fileExists(atPath: localCodex.path) {
                return localCodex
            }
            return nil
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        guard url.lastPathComponent == ".codex" || url.lastPathComponent == "sessions" else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        activeURL = url
        if stale { saveBookmark(for: url) }
        return url
    }

    func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = tr("选择 Codex 数据文件夹", "Choose Codex Data Folder")
        panel.message = tr("请选择 .codex 中的 sessions 文件夹。AI Usage Bar 只会读取其中的本地记录。", "Choose the sessions folder inside .codex. AI Usage Bar reads local records only.")
        panel.prompt = tr("授权只读访问", "Allow Read-Only Access")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        panel.nameFieldStringValue = "sessions"
        guard panel.runModal() == .OK, let url = panel.url,
              (url.lastPathComponent == ".codex" || url.lastPathComponent == "sessions"),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }

        if let activeURL { activeURL.stopAccessingSecurityScopedResource() }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        activeURL = url
        saveBookmark(for: url)
        return url
    }

    private func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }
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
    var fiveHour: QuotaWindow?
    var weekly: QuotaWindow?
    var creditBalance: Double?
    var projects: [ProjectUsage] = []
    var updatedAt: Date?
    var isLiveCodexData = false
}

enum LocalCodexReader {
    static var roots: [URL] {
        guard let root = CodexFolderAccess.shared.currentURL() else { return [] }
        if root.lastPathComponent == "sessions" { return [root] }
        return [root.appendingPathComponent("sessions"), root.appendingPathComponent("archived_sessions")]
    }

    static func snapshot(includeProjects: Bool = true) -> Snapshot {
        let files = logFiles()
        var result = Snapshot()
        let records = files.compactMap { file -> (LogFile, Record)? in
            guard let record = latestRecord(in: file.url) else { return nil }
            return (file, record)
        }

        // A session file can be touched long after its last quota event.  Pick
        // the most recent event timestamp instead of the filesystem mtime.
        func latestCodexRecord(for minutes: Int) -> (LogFile, Record)? {
            records
                .filter {
                    $0.1.limitID == "codex" &&
                    $0.1.limits?.contains(where: { $0.minutes == minutes }) == true
                }
                .max { lhs, rhs in
                    let leftDate = lhs.1.timestamp ?? lhs.0.modified
                    let rightDate = rhs.1.timestamp ?? rhs.0.modified
                    return leftDate < rightDate
                }
        }

        let latestWeekly = latestCodexRecord(for: 10_080)
        let latestFiveHour = latestCodexRecord(for: 300)
        if let latestFiveHour {
            result.fiveHour = latestFiveHour.1.limits?.first { $0.minutes == 300 }
        }
        if let latestWeekly {
            let file = latestWeekly.0
            let record = latestWeekly.1
            result.updatedAt = record.timestamp ?? file.modified
            result.weekly = record.limits?.first { $0.minutes == 10_080 }
            result.creditBalance = record.creditBalance
        }

        if includeProjects {
            let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            var totals: [String: Int64] = [:]
            for (file, record) in records {
                let eventDate = record.timestamp ?? file.modified
                guard eventDate >= cutoff, record.tokens > 0 else { continue }
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
        var creditBalance: Double?
        var limitID: String?
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
                record.limitID = limits["limit_id"] as? String
                record.limits = ["primary", "secondary"].compactMap { key in
                    guard let item = limits[key] as? [String: Any],
                          let used = number(item["used_percent"]),
                          let minutes = item["window_minutes"] as? Int,
                          let reset = number(item["resets_at"]) else { return nil }
                    return QuotaWindow(used: used, minutes: minutes, reset: Date(timeIntervalSince1970: reset))
                }
                if let credits = limits["credits"] as? [String: Any],
                   credits["unlimited"] as? Bool != true,
                   let balance = number(credits["balance"]) {
                    record.creditBalance = balance
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

/// Reads the same rate-limit snapshot exposed by the locally installed Codex
/// app-server. This avoids treating archived session JSONL files as live usage.
enum CodexAppServerReader {
    private static let executable = "/Applications/ChatGPT.app/Contents/Resources/codex"

    static func liveSnapshot() -> Snapshot? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 25, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        func send(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data("\n".utf8))
        }

        send([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": ["name": "CodeX Usage Bar", "version": "1.5"],
                "capabilities": ["experimentalApi": false],
            ],
        ])
        // Wait for protocol responses, not an arbitrary startup delay. Keep
        // stdin open until the account response arrives or the deadline fires.
        var pending = Data()
        var response: [String: Any]?
        while response == nil {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let item = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if (item["id"] as? Int) == 1 {
                    guard item["result"] != nil else { return nil }
                    send(["method": "initialized"])
                    send(["id": 2, "method": "account/rateLimits/read", "params": NSNull()])
                } else if (item["id"] as? Int) == 2 {
                    response = item
                    break
                }
            }
        }
        guard let response,
              let data = try? JSONSerialization.data(withJSONObject: response),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n") {
            guard let item = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (item["id"] as? NSNumber)?.intValue == 2,
                  let result = item["result"] as? [String: Any],
                  let limits = result["rateLimits"] as? [String: Any],
                  limits["limitId"] as? String == "codex" else { continue }

            var snapshot = Snapshot()
            snapshot.fiveHour = window(limits["primary"])
            snapshot.weekly = window(limits["secondary"])
            if let credits = limits["credits"] as? [String: Any],
               credits["unlimited"] as? Bool != true {
                snapshot.creditBalance = number(credits["balance"])
            }
            snapshot.updatedAt = Date()
            snapshot.isLiveCodexData = snapshot.fiveHour != nil || snapshot.weekly != nil
            return snapshot.isLiveCodexData ? snapshot : nil
        }
        return nil
    }

    private static func window(_ value: Any?) -> QuotaWindow? {
        guard let item = value as? [String: Any],
              let used = number(item["usedPercent"]),
              let minutes = (item["windowDurationMins"] as? NSNumber)?.intValue,
              let reset = number(item["resetsAt"]) else { return nil }
        return QuotaWindow(used: used, minutes: minutes, reset: Date(timeIntervalSince1970: reset))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
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
    private var isRefreshing = false
    private var refreshFailed = false
    private let defaults = UserDefaults.standard
    private let codexBundleID = "com.openai.codex"

    private var showWeekly: Bool {
        get { defaults.object(forKey: "showWeekly") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showWeekly") }
    }

    private var showFiveHour: Bool {
        get { defaults.object(forKey: "showFiveHour") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "showFiveHour") }
    }

    /// Keeps the app alive as a lightweight menu-bar process so it can react
    /// to the next Codex launch in the same login session.
    private var followCodexLaunch: Bool {
        get { defaults.bool(forKey: "followCodexLaunch") }
        set { defaults.set(newValue, forKey: "followCodexLaunch") }
    }

    private var quitWithCodex: Bool {
        get {
            defaults.object(forKey: "quitWithCodex") as? Bool
                ?? defaults.bool(forKey: "followCodexQuit")
        }
        set { defaults.set(newValue, forKey: "quitWithCodex") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--check-usage") {
            let started = Date()
            if let live = CodexAppServerReader.liveSnapshot() {
                print("fiveHourRemaining=\(live.fiveHour?.remaining ?? -1) weeklyRemaining=\(live.weekly?.remaining ?? -1) elapsed=\(Date().timeIntervalSince(started))")
                exit(0)
            }
            print("Live quota request failed or timed out")
            exit(1)
        }
        NSApp.setActivationPolicy(.accessory)
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.toolTip = tr("CodeX Usage Bar（每周余量）", "CodeX Usage Bar (weekly remaining)")
        statusItem.button?.imagePosition = .imageLeading
        observeCodexLifecycle()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
        rebuildMenu()
        if followCodexLaunch && !isCodexRunning { statusItem.isVisible = false }
        if CodexFolderAccess.shared.currentURL() == nil {
            DispatchQueue.main.async { [weak self] in self?.chooseCodexFolder() }
        }
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
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshFailed = false
        let needsProjects = Date().timeIntervalSince(lastProjectRefresh) >= 60 * 60
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let live = CodexAppServerReader.liveSnapshot()
            DispatchQueue.main.async {
                self.isRefreshing = false
                self.refreshFailed = live == nil
                if let live {
                    self.snapshot.fiveHour = live.fiveHour
                    self.snapshot.weekly = live.weekly
                    self.snapshot.creditBalance = live.creditBalance
                    self.snapshot.updatedAt = live.updatedAt
                    self.snapshot.isLiveCodexData = true
                }
                self.updateTitle()
                self.rebuildMenu()
            }
            if needsProjects {
                let projects = LocalCodexReader.snapshot(includeProjects: true).projects
                DispatchQueue.main.async {
                    self.snapshot.projects = projects
                    self.lastProjectRefresh = Date()
                    self.rebuildMenu()
                }
            }
        }
    }

    private func updateTitle() {
        let values = [
            showFiveHour ? quotaText(snapshot.fiveHour, creditBalance: nil) : nil,
            showWeekly ? quotaText(snapshot.weekly, creditBalance: snapshot.creditBalance) : nil,
        ].compactMap { $0 }
        statusItem.button?.title = values.joined(separator: "/")
        statusItem.button?.image = quotaIcon(
            fiveHourRemaining: snapshot.fiveHour?.remaining,
            weeklyRemaining: snapshot.weekly?.remaining
        )
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        addHeader("CodeX Usage Bar")
        if isRefreshing {
            addDisabled(tr("正在刷新实时额度…", "Refreshing live usage…"))
        } else if refreshFailed {
            addDisabled(tr("刷新失败 · 以下为上次成功读取值", "Refresh failed · showing last successful values"))
        }
        addQuota(tr("5 小时余量", "5-Hour Remaining"), snapshot.fiveHour, creditBalance: nil)
        addQuota(tr("每周余量", "Weekly Remaining"), snapshot.weekly, creditBalance: snapshot.creditBalance)

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
        let chooseFolder = NSMenuItem(title: tr("选择 Codex 数据文件夹…", "Choose Codex Data Folder…"), action: #selector(chooseCodexFolder), keyEquivalent: "")
        chooseFolder.target = self
        menu.addItem(chooseFolder)
        addToggle(tr("菜单栏显示 5 小时余量", "Show 5-hour remaining in menu bar"), action: #selector(toggleFiveHour), enabled: showFiveHour)
        addToggle(tr("菜单栏显示每周余量", "Show weekly remaining in menu bar"), action: #selector(toggleWeekly), enabled: showWeekly)
        addToggle(tr("Codex 启动时显示 CodeX Usage Bar", "Show CodeX Usage Bar when Codex opens"), action: #selector(toggleFollowCodexLaunch), enabled: followCodexLaunch)
        addToggle(tr("Codex 退出时退出 CodeX Usage Bar", "Quit CodeX Usage Bar when Codex quits"), action: #selector(toggleQuitWithCodex), enabled: quitWithCodex)
        addDisabled(tr("独立第三方本地工具", "Independent third-party local utility"))
        if let updated = snapshot.updatedAt {
            addDisabled(
                tr(snapshot.isLiveCodexData ? "Codex 实时更新：" : "本地记录更新：",
                   snapshot.isLiveCodexData ? "Codex live update: " : "Local record updated: ")
                + dateText(updated)
            )
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

    private func addQuota(_ title: String, _ window: QuotaWindow?, creditBalance: Double?) {
        guard let window else {
            addRow(title: title, detail: tr("本机最新记录未返回此窗口", "Latest local record did not include this window"), value: 0)
            return
        }
        if window.remaining <= 0, let creditBalance {
            let detail = tr("额度已用完 · 可用余额", "Quota exhausted · available balance")
            addRow(title: "\(title)  \(dollarText(creditBalance))", detail: detail, value: 0)
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

    private func quotaText(_ window: QuotaWindow?, creditBalance: Double?) -> String {
        if let window, window.remaining <= 0, let creditBalance {
            return dollarText(creditBalance)
        }
        return window.map { "\(Int($0.remaining.rounded()))%" } ?? "--"
    }

    private func dollarText(_ amount: Double) -> String {
        String(format: "US$%.2f", amount)
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

    @objc private func toggleFiveHour() {
        showFiveHour.toggle()
        updateTitle()
        rebuildMenu()
    }

    @objc private func toggleQuitWithCodex() {
        quitWithCodex.toggle()
        rebuildMenu()
    }

    @objc private func toggleFollowCodexLaunch() {
        followCodexLaunch.toggle()
        if followCodexLaunch {
            // A terminated app cannot observe the next Codex launch. Keep it
            // resident and hide its status item between Codex sessions.
            quitWithCodex = false
        }
        updateLoginItem()
        statusItem.isVisible = !followCodexLaunch || isCodexRunning
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
        if followCodexLaunch, bundleID(from: notification) == codexBundleID {
            statusItem.isVisible = false
            return
        }
        guard quitWithCodex, bundleID(from: notification) == codexBundleID else { return }
        NSApplication.shared.terminate(nil)
    }

    private func bundleID(from notification: Notification) -> String? {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
    }

    private func updateLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if followCodexLaunch {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            // It still works for this login session if macOS declines the
            // optional login-item registration.
        }
    }

    @objc private func chooseCodexFolder() {
        guard CodexFolderAccess.shared.chooseFolder() != nil else { return }
        lastProjectRefresh = .distantPast
        refresh()
        rebuildMenu()
    }

    private func appIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    private func quotaIcon(fiveHourRemaining: Double?, weeklyRemaining: Double?) -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let center = NSPoint(x: 9, y: 9)
        func ring(remaining: Double?, radius: CGFloat, lineWidth: CGFloat, color: NSColor) {
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor(calibratedWhite: 0.7, alpha: 0.28).setStroke()
            track.stroke()

            guard let remaining else { return }
            let value = max(0, min(100, remaining))
            let used = 100 - value
            let progress = NSBezierPath()
            progress.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90 - CGFloat(used / 100 * 360),
                endAngle: -270,
                clockwise: true
            )
            progress.lineWidth = lineWidth
            progress.lineCapStyle = .round
            color.setStroke()
            progress.stroke()
        }

        // Outer blue ring: 5-hour remaining. Inner green ring: weekly remaining.
        ring(
            remaining: fiveHourRemaining,
            radius: 8,
            lineWidth: 1.15,
            color: NSColor(srgbRed: 0.20, green: 0.58, blue: 1.0, alpha: 1)
        )
        ring(
            remaining: weeklyRemaining,
            radius: 6.15,
            lineWidth: 1.8,
            color: NSColor(srgbRed: 0.16, green: 0.95, blue: 0.49, alpha: 1)
        )

        // The status-bar glyph deliberately uses a transparent canvas instead
        // of the full app icon, whose white rounded-square background becomes
        // visually heavy at 18 pt.
        let terminal = NSBezierPath()
        terminal.move(to: NSPoint(x: 5.2, y: 11.6))
        terminal.line(to: NSPoint(x: 7.8, y: 9))
        terminal.line(to: NSPoint(x: 5.2, y: 6.4))
        terminal.lineWidth = 1.7
        terminal.lineCapStyle = .round
        terminal.lineJoinStyle = .round
        NSColor.white.setStroke()
        terminal.stroke()

        let cursor = NSBezierPath()
        cursor.move(to: NSPoint(x: 9.4, y: 6.1))
        cursor.line(to: NSPoint(x: 12.7, y: 6.1))
        cursor.lineWidth = 1.7
        cursor.lineCapStyle = .round
        NSColor.white.setStroke()
        cursor.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
}

//
//  CodeXUsageBarApp.swift
//  CodeXUsageBar
//
//  Created by Daniel Dai on 2026/8/15.
//

import SwiftUI

@main
struct CodeXUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
