// LiveSubs: captures system audio with ScreenCaptureKit, pipes it to worker.py,
// and shows the returned subtitles in a floating always-on-top window.
// Build: ./build.sh   Run: ./LiveSubs [worker.py options, e.g. --model gemma4-uncensored]

import AppKit
import CoreMedia
import ScreenCaptureKit

let sampleRate = 16000

// MARK: - Worker process

final class Worker {
    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    var onMessage: (([String: Any]) -> Void)?
    private var lineBuffer = Data()

    init(dir: URL, args: [String]) {
        process.executableURL = dir.appendingPathComponent(".venv/bin/python")
        process.arguments = [dir.appendingPathComponent("worker.py").path] + args
        process.currentDirectoryURL = dir
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
    }

    func start() throws {
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let chunk = h.availableData
            if chunk.isEmpty { return }
            self.lineBuffer.append(chunk)
            while let nl = self.lineBuffer.firstIndex(of: 0x0A) {
                let line = self.lineBuffer[self.lineBuffer.startIndex..<nl]
                self.lineBuffer.removeSubrange(self.lineBuffer.startIndex...nl)
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    DispatchQueue.main.async { self.onMessage?(obj) }
                }
            }
        }
        process.terminationHandler = { p in
            FileHandle.standardError.write("[LiveSubs] worker exited (\(p.terminationStatus))\n".data(using: .utf8)!)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        try process.run()
    }

    func write(_ data: Data) {
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }
}

// MARK: - System audio capture

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "livesubs.audio")
    private var loggedFormat = false
    var onPCM: ((Data) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw NSError(domain: "LiveSubs", code: 1) }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = sampleRate
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        // Video can't be turned off entirely; keep it tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let fmt = sb.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        if !loggedFormat {
            loggedFormat = true
            FileHandle.standardError.write("[LiveSubs] audio: \(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, flags \(asbd.mFormatFlags)\n".data(using: .utf8)!)
        }
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let ptr = abl.mBuffers.mData else { return }
        // Mono float32 requested; first buffer is channel 0 either way.
        onPCM?(Data(bytes: ptr, count: Int(abl.mBuffers.mDataByteSize)))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("[LiveSubs] capture stopped: \(error.localizedDescription)\n".data(using: .utf8)!)
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

// MARK: - Overlay window

final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // let drags reach the window
}

final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class Overlay {
    let panel: NSPanel
    let label = PassthroughLabel(wrappingLabelWithString: "")
    let box = DragView()
    var fontSize: CGFloat = 32
    var userMoved = false
    private var hideTimer: Timer?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        box.layer?.cornerRadius = 10
        label.alignment = .center
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
        ])
        panel.contentView = box
        applyFonts()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            self?.userMoved = true
        }
    }

    var width: CGFloat {
        let screen = NSScreen.main?.visibleFrame.width ?? 1400
        return min(1375, screen * 0.875)
    }

    func applyFonts() {
        label.font = .systemFont(ofSize: fontSize, weight: .semibold)
        label.preferredMaxLayoutWidth = width - 36
        relayout()
    }

    func relayout() {
        box.layoutSubtreeIfNeeded()
        let h = box.fittingSize.height
        var f = panel.frame
        if userMoved {
            f.origin.y += f.height - h  // keep the top edge where the user put it
        } else if let s = NSScreen.main?.visibleFrame {
            f.origin = NSPoint(x: s.midX - width / 2, y: s.minY + 60)
        }
        f.size = NSSize(width: width, height: h)
        let moved = userMoved
        panel.setFrame(f, display: true)
        userMoved = moved  // programmatic moves don't count
    }

    func resetPosition() {
        userMoved = false
        relayout()
    }

    /// Subtitles in white; status messages (loading, listening) dimmed.
    func show(_ text: String, dim: Bool = false) {
        label.stringValue = text
        label.textColor = dim ? NSColor(white: 0.7, alpha: 1) : .white
        relayout()
        panel.alphaValue = text.isEmpty ? 0 : 1
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: dim ? 600 : 8, repeats: false) { [weak self] _ in
            self?.panel.alphaValue = 0
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let overlay = Overlay()
    let capture = AudioCapture()
    var worker: Worker!
    var statusItem: NSStatusItem!
    var lines: [String] = []  // recent subtitle lines

    func applicationDidFinishLaunching(_ note: Notification) {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        worker = Worker(dir: dir, args: Array(CommandLine.arguments.dropFirst()))
        worker.onMessage = { [weak self] in self?.handle($0) }
        capture.onPCM = { [weak self] in self?.worker.write($0) }
        setupMenu()
        overlay.show("Starting…", dim: true)
        do { try worker.start() } catch {
            fail("could not start worker: \(error)")
        }
    }

    func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "status":
            overlay.show(msg["text"] as? String ?? "", dim: true)
        case "ready":
            if CommandLine.arguments.contains("--file") {  // worker reads a file itself: no capture
                overlay.show("Playing file…", dim: true)
                return
            }
            Task {
                do {
                    try await capture.start()
                    await MainActor.run { self.overlay.show("Listening…", dim: true) }
                } catch {
                    self.fail("""
                        could not capture system audio: \(error.localizedDescription)
                        Grant access in System Settings → Privacy & Security → Screen & System Audio Recording
                        to the app you launched this from (e.g. Terminal), then run again.
                        """)
                }
            }
        case "line":
            lines.append(msg["text"] as? String ?? "")
            lines = Array(lines.suffix(2))
            overlay.show(lines.joined(separator: "\n"))
        default: break
        }
    }

    func fail(_ message: String) {
        FileHandle.standardError.write("[LiveSubs] \(message)\n".data(using: .utf8)!)
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Subs"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Larger text", action: #selector(larger), keyEquivalent: "+"))
        menu.addItem(NSMenuItem(title: "Smaller text", action: #selector(smaller), keyEquivalent: "-"))
        menu.addItem(NSMenuItem(title: "Reset position", action: #selector(resetPosition), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LiveSubs", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    @objc func larger() { overlay.fontSize += 2; overlay.applyFonts() }
    @objc func smaller() { overlay.fontSize = max(12, overlay.fontSize - 2); overlay.applyFonts() }
    @objc func resetPosition() { overlay.resetPosition() }
    @objc func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ note: Notification) {
        if worker?.process.isRunning == true { worker.process.terminate() }
    }
}

signal(SIGINT) { _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
