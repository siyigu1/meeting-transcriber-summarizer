// meetingbar.swift — menu bar UI for meeting-record.sh
//
// Build:  swiftc -O -o meetingbar meetingbar.swift
// Run:    ./meetingbar   (or install at login via: ./meeting-record.sh watch-install,
//         which prefers this binary over the headless watcher when it exists)
//
// What it does:
//   - Always-on menu bar item: shows recorder state, lets you start/stop manually.
//   - Polls for a live call (via meeting-record.sh call-check). When a meeting is
//     detected and nothing is recording, a small floating panel appears at the
//     top-right of the main display asking whether to record.
//   - While recording, the panel stays visible with a red dot + elapsed time and
//     a Stop button. Stopping triggers the daemon's auto-transcription; the panel
//     shows progress and a "transcript ready" confirmation.
//
// All recording/transcription logic lives in meeting-record.sh — this is a thin
// UI shell around it, so script-only (headless) usage keeps working.

import AppKit

let selfDir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().path
let scriptPath = selfDir + "/meeting-record.sh"

@discardableResult
func sh(_ args: [String], timeout: TimeInterval = 30) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: scriptPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (127, "") }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(100_000) }
    if p.isRunning { p.terminate() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

struct SessionState {
    var dir = ""
    var status = ""
    var seconds = 0
    var transcribe = ""
}

enum Mode: Equatable { case idle, prompt, starting, recording, paused, transcribing, done }

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var baseDir = NSString(string: "~/meetings").expandingTildeInPath

    var mode = Mode.idle
    var ignoredThisCall = false
    var inactivePolls = 0
    var pollBusy = false
    var tickCount = 0
    var doneUntil = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        let info = sh(["info"], timeout: 10).out
        for line in info.split(separator: "\n") where line.hasPrefix("base_dir=") {
            baseDir = String(line.dropFirst("base_dir=".count))
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = makePanel()
        updateUI()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        detectionPoll()
    }

    // ---------- state reading ----------

    func readState() -> SessionState? {
        guard let cur = try? String(contentsOfFile: baseDir + "/.current-session", encoding: .utf8)
        else { return nil }
        var s = SessionState()
        s.dir = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw = try? String(contentsOfFile: s.dir + "/state", encoding: .utf8)
        else { return nil }
        for line in raw.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "status": s.status = kv[1]
            case "recorded_seconds": s.seconds = Int(kv[1]) ?? 0
            case "transcribe": s.transcribe = kv[1]
            default: break
            }
        }
        return s
    }

    func stateFresh(_ dir: String, within: TimeInterval) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dir + "/state"),
              let m = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(m) < within
    }

    // ---------- polling ----------

    func tick() {
        tickCount += 1
        let s = readState()
        var newMode = mode
        if let st = s, st.status == "recording", stateFresh(st.dir, within: 20) {
            newMode = .recording
        } else if let st = s, st.status == "paused", stateFresh(st.dir, within: 20) {
            newMode = .paused
        } else if let st = s, st.status == "ended", st.transcribe == "running" {
            newMode = .transcribing
        } else {
            if mode == .transcribing, s?.transcribe == "done" {
                newMode = .done
                doneUntil = Date().addingTimeInterval(30)
            } else if mode == .done {
                newMode = Date() < doneUntil ? .done : .idle
            } else if mode == .recording || mode == .paused || mode == .transcribing {
                newMode = .idle   // session vanished or was ended elsewhere
            }
            // .idle / .prompt / .starting are managed by detectionPoll + actions
        }
        if newMode != mode { mode = newMode; updateUI() }
        else if mode == .recording || mode == .paused { updateUI() }  // refresh elapsed time
        if tickCount % 10 == 0 { detectionPoll() }
    }

    func detectionPoll() {
        guard mode == .idle || mode == .prompt, !pollBusy else { return }
        pollBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let active = sh(["call-check"], timeout: 15).code == 0
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pollBusy = false
                guard self.mode == .idle || self.mode == .prompt else { return }
                if active {
                    self.inactivePolls = 0
                    if !self.ignoredThisCall && self.mode == .idle {
                        self.mode = .prompt
                        self.updateUI()
                    }
                } else {
                    self.inactivePolls += 1
                    if self.inactivePolls >= 2 {
                        self.ignoredThisCall = false
                        if self.mode == .prompt { self.mode = .idle; self.updateUI() }
                    }
                }
            }
        }
    }

    // ---------- actions ----------

    @objc func doRecord() {
        mode = .starting
        updateUI()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            sh(["watch-start"], timeout: 30)
            DispatchQueue.main.async { self?.tick() }
        }
    }

    @objc func doIgnore() {
        ignoredThisCall = true
        mode = .idle
        updateUI()
    }

    @objc func doStop() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            sh(["ctl", "end"], timeout: 15)
            DispatchQueue.main.async { self?.tick() }
        }
    }

    @objc func doPause() { DispatchQueue.global().async { sh(["ctl", "pause"], timeout: 15) } }
    @objc func doResume() { DispatchQueue.global().async { sh(["ctl", "resume"], timeout: 15) } }

    @objc func doDismissDone() {
        doneUntil = .distantPast
        mode = .idle
        updateUI()
    }

    @objc func doOpenFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: baseDir))
    }

    // ---------- UI ----------

    func fmt(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                  : String(format: "%d:%02d", s / 60, s % 60)
    }

    func updateUI() {
        let secs = readState()?.seconds ?? 0
        let title: String
        let statusText: String
        switch mode {
        case .idle:
            title = "🎙"; statusText = "Idle — watching for meetings"
        case .prompt:
            title = "🎙"; statusText = "Meeting detected"
        case .starting:
            title = "⏳"; statusText = "Starting recorder…"
        case .recording:
            title = "🔴 " + fmt(secs); statusText = "Recording — " + fmt(secs)
        case .paused:
            title = "⏸ " + fmt(secs); statusText = "Paused — " + fmt(secs)
        case .transcribing:
            title = "📝"; statusText = "Transcribing…"
        case .done:
            title = "🎙"; statusText = "Transcript ready"
        }
        statusItem.button?.title = title
        statusItem.menu = buildMenu(statusText)

        switch mode {
        case .prompt:
            showPanel(text: "A meeting looks live.\nRecord it?",
                      buttons: [("Record", #selector(doRecord)), ("Ignore", #selector(doIgnore))])
        case .starting:
            showPanel(text: "Starting recorder…", buttons: [])
        case .recording:
            showPanel(text: "🔴 Recording — " + fmt(secs),
                      buttons: [("Stop", #selector(doStop))])
        case .paused:
            showPanel(text: "⏸ Paused — " + fmt(secs),
                      buttons: [("Resume", #selector(doResume)), ("Stop", #selector(doStop))])
        case .transcribing:
            showPanel(text: "📝 Transcribing…\n(~2.5x realtime; safe to walk away)", buttons: [])
        case .done:
            showPanel(text: "✅ Transcript ready.\nSummarize with /meeting-notes.",
                      buttons: [("Close", #selector(doDismissDone))])
        case .idle:
            panel.orderOut(nil)
        }
    }

    func buildMenu(_ status: String) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let header = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        m.addItem(.separator())
        func item(_ title: String, _ sel: Selector) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }
        switch mode {
        case .recording:
            item("Stop Recording (ends + transcribes)", #selector(doStop))
            item("Pause", #selector(doPause))
        case .paused:
            item("Stop Recording (ends + transcribes)", #selector(doStop))
            item("Resume", #selector(doResume))
        case .starting, .transcribing:
            break
        default:
            item("Start Recording Now", #selector(doRecord))
        }
        m.addItem(.separator())
        item("Open Meetings Folder", #selector(doOpenFolder))
        let q = NSMenuItem(title: "Quit Meeting Recorder",
                           action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        m.addItem(q)
        return m
    }

    func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 90),
                        styleMask: [.titled, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "Meeting Recorder"
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        return p
    }

    func showPanel(text: String, buttons: [(String, Selector)]) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .center
        var views: [NSView] = [label]
        if !buttons.isEmpty {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            for (title, sel) in buttons {
                let b = NSButton(title: title, target: self, action: sel)
                b.bezelStyle = .rounded
                row.addArrangedSubview(b)
            }
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - panel.frame.width - 16,
                                         y: f.maxY - panel.frame.height - 16))
        }
        panel.orderFrontRegardless()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
