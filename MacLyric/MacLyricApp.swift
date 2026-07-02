//
//  MacLyricApp.swift
//  MacLyric
//
//  Created by 刘鑫 on 2026/6/30.
//
import SwiftUI
import Cocoa
import Combine

// MARK: - Color 扩展

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default: return nil
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }

    var hexString: String {
        guard let cgColor = self.cgColor else { return "#FFFFFF" }
        let nsColor = NSColor(cgColor: cgColor) ?? .white
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return "#FFFFFF" }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// 说明：
// 1. 新增「逐字歌词」(网易云 yrc 接口)，配合 SwiftUI 动画实现类似 Apple Music 的渐进高亮效果；
//    若歌曲没有逐字歌词，会自动回退到普通逐行 lrc（整行淡入）。
// 2. 新增菜单栏图标，可在其中调整歌词字号、锁定/解锁窗口、重置窗口位置。
// 3. 「锁定」时窗口鼠标穿透、不可拖动；「解锁」时窗口可被拖到任意位置，并显示半透明背景便于操作，
//    位置会通过 NSWindow 的 autosave 机制自动保存，下次启动自动恢复。
// 4. 本文件需要 macOS 12.0+（用到了 TimelineView / mask 等较新 API）。

@main
struct MacLyricApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() } // 隐藏默认的设置窗口
    }
}

// MARK: - 全局设置（持久化到 UserDefaults）

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var fontSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(fontSize), forKey: "lyric.fontSize") }
    }

    @Published var isLocked: Bool {
        didSet { UserDefaults.standard.set(isLocked, forKey: "lyric.isLocked") }
    }

    @Published var isPinned: Bool {
        didSet { UserDefaults.standard.set(isPinned, forKey: "lyric.isPinned") }
    }

    @Published var primaryColorHex: String {
        didSet { UserDefaults.standard.set(primaryColorHex, forKey: "lyric.primaryColor") }
    }

    @Published var secondaryColorHex: String {
        didSet { UserDefaults.standard.set(secondaryColorHex, forKey: "lyric.secondaryColor") }
    }

    var effectiveGradient: [Color] {
        [Color(hex: primaryColorHex) ?? .white, Color(hex: secondaryColorHex) ?? .cyan]
    }

    private init() {
        let savedSize = UserDefaults.standard.double(forKey: "lyric.fontSize")
        self.fontSize = savedSize > 0 ? CGFloat(savedSize) : 44

        if UserDefaults.standard.object(forKey: "lyric.isLocked") == nil {
            self.isLocked = true
        } else {
            self.isLocked = UserDefaults.standard.bool(forKey: "lyric.isLocked")
        }

        self.isPinned = UserDefaults.standard.object(forKey: "lyric.isPinned") as? Bool ?? true
        self.primaryColorHex = UserDefaults.standard.string(forKey: "lyric.primaryColor") ?? "#FFFFFF"
        self.secondaryColorHex = UserDefaults.standard.string(forKey: "lyric.secondaryColor") ?? "#00D4FF"
    }
}

// MARK: - 窗口控制层

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!

    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupWindow()
        setupStatusItem()
        observeSettings()
    }

    private func setupWindow() {
        let defaultFrame = NSRect(x: 0, y: 0, width: 900, height: 140)
        window = NSWindow(
            contentRect: defaultFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = settings.isPinned ? .floating : .normal
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: LyricView())

        window.center()
        window.setFrameAutosaveName("MacLyricFloatingWindow")

        applyLockState(settings.isLocked)
        window.makeKeyAndOrderFront(nil)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "歌词")
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let lockTitle = settings.isLocked ? "🔓 解锁窗口" : "🔒 锁定窗口"
        let lockItem = NSMenuItem(title: lockTitle, action: #selector(toggleLock), keyEquivalent: "l")
        lockItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(lockItem)

        menu.addItem(.separator())

        let pinTitle = settings.isPinned ? "📍 取消置顶（允许被覆盖）" : "📌 置顶（保持最前）"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(togglePin), keyEquivalent: "p")
        pinItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let fontMenu = NSMenu()
        let presets: [(String, CGFloat)] = [("小", 32), ("中", 44), ("大", 56), ("特大", 68)]
        for (label, size) in presets {
            let item = NSMenuItem(title: label, action: #selector(setFontSize(_:)), keyEquivalent: "")
            item.representedObject = size
            item.state = (settings.fontSize == size) ? .on : .off
            fontMenu.addItem(item)
        }
        let fontMenuItem = NSMenuItem(title: "歌词字号", action: nil, keyEquivalent: "")
        fontMenuItem.submenu = fontMenu
        menu.addItem(fontMenuItem)

        let increaseItem = NSMenuItem(title: "增大字号", action: #selector(increaseFont), keyEquivalent: "=")
        increaseItem.keyEquivalentModifierMask = [.command]
        menu.addItem(increaseItem)

        let decreaseItem = NSMenuItem(title: "减小字号", action: #selector(decreaseFont), keyEquivalent: "-")
        decreaseItem.keyEquivalentModifierMask = [.command]
        menu.addItem(decreaseItem)

        menu.addItem(.separator())

        let colorMenu = NSMenu()
        colorMenu.addItem(NSMenuItem(title: "设置主色…", action: #selector(pickPrimaryColor), keyEquivalent: ""))
        colorMenu.addItem(NSMenuItem(title: "设置辅色…", action: #selector(pickSecondaryColor), keyEquivalent: ""))
        colorMenu.addItem(NSMenuItem(title: "重置为默认", action: #selector(resetColors), keyEquivalent: ""))
        let colorMenuItem = NSMenuItem(title: "歌词颜色", action: nil, keyEquivalent: "")
        colorMenuItem.submenu = colorMenu
        menu.addItem(colorMenuItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "重置窗口位置", action: #selector(resetPosition), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func observeSettings() {
        settings.$isLocked
            .sink { [weak self] locked in
                self?.applyLockState(locked)
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        settings.$fontSize
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        settings.$isPinned
            .sink { [weak self] pinned in
                self?.window?.level = pinned ? .floating : .normal
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private func applyLockState(_ locked: Bool) {
        window.ignoresMouseEvents = locked
        window.isMovableByWindowBackground = !locked
    }

    @objc private func toggleLock() {
        settings.isLocked.toggle()
    }

    @objc private func togglePin() {
        settings.isPinned.toggle()
    }

    @objc private func setFontSize(_ sender: NSMenuItem) {
        if let size = sender.representedObject as? CGFloat {
            settings.fontSize = size
        }
    }

    @objc private func increaseFont() {
        settings.fontSize = min(settings.fontSize + 4, 96)
    }

    @objc private func decreaseFont() {
        settings.fontSize = max(settings.fontSize - 4, 20)
    }

    @objc private func pickPrimaryColor() {
        let panel = NSColorPanel.shared
        panel.setAction(#selector(primaryColorChanged(_:)))
        panel.setTarget(self)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func primaryColorChanged(_ sender: NSColorPanel) {
        guard let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        settings.primaryColorHex = String(format: "#%02X%02X%02X",
                                          Int(rgb.redComponent * 255),
                                          Int(rgb.greenComponent * 255),
                                          Int(rgb.blueComponent * 255))
    }

    @objc private func pickSecondaryColor() {
        let panel = NSColorPanel.shared
        panel.setAction(#selector(secondaryColorChanged(_:)))
        panel.setTarget(self)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func secondaryColorChanged(_ sender: NSColorPanel) {
        guard let rgb = sender.color.usingColorSpace(.sRGB) else { return }
        settings.secondaryColorHex = String(format: "#%02X%02X%02X",
                                            Int(rgb.redComponent * 255),
                                            Int(rgb.greenComponent * 255),
                                            Int(rgb.blueComponent * 255))
    }

    @objc private func resetColors() {
        settings.primaryColorHex = "#FFFFFF"
        settings.secondaryColorHex = "#00D4FF"
    }

    @objc private func resetPosition() {
        window.center()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - UI 渲染层

struct LyricView: View {
    @StateObject private var engine = LyricEngine()
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        ZStack {
            if !settings.isLocked {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.black.opacity(0.35))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
                    )
            }

            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                KaraokeLineView(
                    line: engine.currentLine,
                    fontSize: settings.fontSize,
                    position: engine.estimatedPosition(at: timeline.date),
                    gradient: settings.effectiveGradient
                )
            }

            if !settings.isLocked {
                VStack {
                    Spacer()
                    Text("拖动此处移动位置 · 菜单栏图标可调整字号/颜色/置顶")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.bottom, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct KaraokeLineView: View {
    let line: LyricLine?
    let fontSize: CGFloat
    let position: Double
    let gradient: [Color]

    var body: some View {
        HStack(spacing: 0) {
            if let line = line, !line.words.isEmpty {
                ForEach(Array(line.words.enumerated()), id: \.offset) { _, word in
                    KaraokeWordView(word: word, fontSize: fontSize, progress: progress(for: word), gradient: gradient)
                }
            } else {
                Text("等待播放…")
                    .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
            }
        }
        .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 2)
    }

    private func progress(for word: LyricWord) -> Double {
        let posMs = position * 1000
        let s = Double(word.startMs), e = Double(word.endMs)
        if posMs <= s { return 0 }
        if posMs >= e { return 1 }
        return (posMs - s) / max(e - s, 1)
    }
}

struct KaraokeWordView: View {
    let word: LyricWord
    let fontSize: CGFloat
    let progress: Double
    let gradient: [Color]

    var body: some View {
        ZStack(alignment: .leading) {
            Text(word.text)
                .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                .foregroundColor(.white.opacity(0.35))

            Text(word.text)
                .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing)
                )
                .mask(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle()
                            .frame(width: geo.size.width * CGFloat(progress))
                    }
                }
        }
    }
}

// MARK: - 歌词数据模型

struct LyricWord: Equatable {
    let startMs: Int
    let endMs: Int
    let text: String
}

struct LyricLine: Equatable {
    let startMs: Int
    let endMs: Int
    let words: [LyricWord]
    var plainText: String { words.map { $0.text }.joined() }
}

// MARK: - 逻辑与数据层

final class LyricEngine: ObservableObject {
    @Published var currentLine: LyricLine? = nil
    @Published var previousLine: LyricLine? = nil
    @Published var nextLine: LyricLine? = nil

    private var pollTimer: Timer?
    private var currentTrackId: String = ""
    private var lines: [LyricLine] = []

    // 两次 AppleScript 轮询之间，用本地时钟推算播放进度，让逐字动画更平滑、
    // 不依赖轮询频率（轮询频率过高会增加系统负担，过低又会让动画卡顿）。
    private var lastKnownPosition: Double = 0
    private var lastSyncDate: Date = Date()
    private var isPlaying: Bool = false

    init() {
        startPolling()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.syncMusicState()
        }
    }

    /// 根据上一次同步到的播放位置 + 经过的真实时间，推算当前播放进度（秒）
    func estimatedPosition(at date: Date = Date()) -> Double {
        guard isPlaying else { return lastKnownPosition }
        return lastKnownPosition + date.timeIntervalSince(lastSyncDate)
    }

    private func syncMusicState() {
        let scriptStr = """
        if application "Music" is running then
            tell application "Music"
                if player state is playing then
                    return name of current track & "|||" & artist of current track & "|||" & player position
                else
                    return "PAUSED"
                end if
            end tell
        end if
        return ""
        """

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            var error: NSDictionary?
            guard let script = NSAppleScript(source: scriptStr) else { return }
            let result = script.executeAndReturnError(&error)
            let text = result.stringValue ?? ""

            if text.isEmpty || text == "PAUSED" {
                DispatchQueue.main.async { self.isPlaying = false }
                return
            }

            let parts = text.components(separatedBy: "|||")
            guard parts.count == 3 else { return }

            let trackName = parts[0]
            let artistName = parts[1]
            let position = Double(parts[2]) ?? 0.0
            let trackId = "\(trackName)-\(artistName)"

            DispatchQueue.main.async {
                self.lastKnownPosition = position
                self.lastSyncDate = Date()
                self.isPlaying = true

                if self.currentTrackId != trackId {
                    self.currentTrackId = trackId
                    self.lines = []
                    self.currentLine = LyricLine(
                        startMs: 0, endMs: 0,
                        words: [LyricWord(startMs: 0, endMs: 0, text: "获取歌词中…")]
                    )
                    self.fetchLyrics(track: trackName, artist: artistName)
                }
                self.updateCurrentLine(positionMs: position * 1000)
            }
        }
    }

    private func updateCurrentLine(positionMs: Double) {
        guard !lines.isEmpty else { return }
        let line = lines.last { Double($0.startMs) <= positionMs } ?? lines.first
        if line != currentLine {
            currentLine = line
        }
        if let idx = currentLine.flatMap({ lines.firstIndex(of: $0) }) {
            previousLine = idx > 0 ? lines[idx - 1] : nil
            nextLine = idx < lines.count - 1 ? lines[idx + 1] : nil
        }
    }

    // MARK: 网络请求

    private func fetchLyrics(track: String, artist: String) {
        let keyword = "\(artist) \(track)"
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let searchUrl = "https://music.163.com/api/search/get/web?csrf_token=&hlpretag=&hlposttag=&s=\(encoded)&type=1&offset=0&total=true&limit=1"

        guard let url = URL(string: searchUrl) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let songs = result["songs"] as? [[String: Any]],
                  let songId = songs.first?["id"] as? Int else {
                DispatchQueue.main.async {
                    self?.currentLine = LyricLine(
                        startMs: 0, endMs: 0,
                        words: [LyricWord(startMs: 0, endMs: 0, text: "未找到歌词")]
                    )
                }
                return
            }
            self.fetchLyricsById(id: songId)
        }.resume()
    }

    private func fetchLyricsById(id: Int) {
        // yv=-1 用于额外请求逐字时间戳的「逐字歌词」(yrc)；
        // 如果该歌曲没有逐字版本，再回退使用普通逐行歌词 (lrc)
        let lyricUrl = "https://music.163.com/api/song/lyric?os=pc&id=\(id)&lv=-1&kv=-1&tv=-1&yv=-1"
        guard let url = URL(string: lyricUrl) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            if let yrc = json["yrc"] as? [String: Any],
               let yrcLyric = yrc["lyric"] as? String,
               !yrcLyric.isEmpty {
                self.parseYRC(yrcLyric)
            } else if let lrc = json["lrc"] as? [String: Any],
                      let lrcLyric = lrc["lyric"] as? String {
                self.parseLRC(lrcLyric)
            }
        }.resume()
    }

    // MARK: 逐字歌词解析 (yrc)
    // 行格式示例：[1280,3960](1280,300,0)我(1580,300,0)们(1880,300,0)的...
    // 即：[行起始ms,行时长ms](字起始ms,字时长ms,flag)字 (字起始ms,字时长ms,flag)字 ...

    private func parseYRC(_ raw: String) {
        var result: [LyricLine] = []
        let rows = raw.components(separatedBy: .newlines)

        guard let headerRegex = try? NSRegularExpression(pattern: "^\\[(\\d+),(\\d+)\\]"),
              let wordRegex = try? NSRegularExpression(pattern: "\\((\\d+),(\\d+),\\d+\\)([^\\(\\[]*)")
        else { return }

        for row in rows {
            let fullRange = NSRange(row.startIndex..., in: row)
            guard let headerMatch = headerRegex.firstMatch(in: row, range: fullRange) else { continue }

            let nsRow = row as NSString
            let lineStart = Int(nsRow.substring(with: headerMatch.range(at: 1))) ?? 0
            let lineDuration = Int(nsRow.substring(with: headerMatch.range(at: 2))) ?? 0

            var words: [LyricWord] = []
            for m in wordRegex.matches(in: row, range: fullRange) {
                let wStart = Int(nsRow.substring(with: m.range(at: 1))) ?? 0
                let wDur = Int(nsRow.substring(with: m.range(at: 2))) ?? 0
                let wText = nsRow.substring(with: m.range(at: 3))
                if !wText.isEmpty {
                    words.append(LyricWord(startMs: wStart, endMs: wStart + wDur, text: wText))
                }
            }

            if !words.isEmpty {
                let lineEnd = lineStart + lineDuration
                result.append(LyricLine(startMs: lineStart, endMs: lineEnd, words: words))
            }
        }

        DispatchQueue.main.async {
            if !result.isEmpty {
                self.lines = result
            }
        }
    }

    // MARK: 逐行歌词解析 (lrc) —— 没有逐字歌词时的兜底方案
    // 没有逐字时间信息，因此把整行当作「一个词」，配合下一行的起始时间得到该行的展示时长，
    // 实现整行淡入高亮（而不是逐字擦亮）

    private func parseLRC(_ lrc: String) {
        var rawLines: [(Int, String)] = []
        let rows = lrc.components(separatedBy: .newlines)
        guard let regex = try? NSRegularExpression(pattern: "\\[(\\d{2}):(\\d{2})[.:](\\d{2,3})\\]") else { return }

        for row in rows {
            let range = NSRange(row.startIndex..., in: row)
            guard let match = regex.firstMatch(in: row, range: range) else { continue }
            let nsRow = row as NSString
            let minStr = nsRow.substring(with: match.range(at: 1))
            let secStr = nsRow.substring(with: match.range(at: 2))
            let msStr = nsRow.substring(with: match.range(at: 3))
            let msValue = (Double(msStr) ?? 0) * (msStr.count == 2 ? 10 : 1)
            let totalMs = (Int(minStr) ?? 0) * 60000 + (Int(secStr) ?? 0) * 1000 + Int(msValue)
            let text = nsRow.substring(from: match.range.upperBound).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                rawLines.append((totalMs, text))
            }
        }

        guard !rawLines.isEmpty else { return }

        var result: [LyricLine] = []
        for (i, entry) in rawLines.enumerated() {
            let nextStart = i + 1 < rawLines.count ? rawLines[i + 1].0 : entry.0 + 4000
            let endMs = entry.0 + max(nextStart - entry.0, 500)
            let word = LyricWord(startMs: entry.0, endMs: endMs, text: entry.1)
            result.append(LyricLine(startMs: entry.0, endMs: endMs, words: [word]))
        }

        DispatchQueue.main.async {
            self.lines = result
        }
    }

}
