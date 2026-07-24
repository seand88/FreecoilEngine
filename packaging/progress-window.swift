// Beyond All Reason — first-run progress window.
//
// A tiny AppKit helper the launcher shows immediately on first run, so the
// one-time lobby download has a real window instead of a silently bouncing
// dock icon. Launched as a child of the .app launcher; reads a line protocol
// on stdin and updates the UI:
//
//   S <text>   set the status line (what is happening right now)
//   D <text>   set the secondary detail line (host, bytes, tag, …)
//   P <int>    determinate progress, 0..100
//   I          indeterminate (pulsing) — unknown-duration step
//   F <text>   finished: set <text>, hide the bar and the Skip button (the
//              launcher then sends "D Launching game…" and holds MIN_DISPLAY)
//   E <text>   error: show <text> in red, stop, reveal a Quit button
//   EOF        success (if no error was shown) → window closes, but never
//
// --skip-file <path>: show a "Skip update" button; clicking it creates the
// file (the launcher polls for it, stops the downloader and starts the game
// on the existing content). Passed only when there IS existing content —
// never on a first run, where skipping would leave nothing to play.
//              before MIN_DISPLAY seconds after it appeared — a no-op update
//              check finishes in well under a second and an unreadable flash
//              of UI looks like a glitch. The launcher does NOT wait for this
//              lingering close (it must not delay the game launch).
//
// On error the window stays up until the user clicks Quit (EOF does not close
// it once in the error state), so the classified failure reason is readable.
import AppKit

let MIN_DISPLAY: TimeInterval = 3.0

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}
let skipFilePath = arg("--skip-file")

// Centre a window on the ACTIVE screen. Duplicated verbatim in the launcher's
// other Swift helpers: each is compiled as a standalone single-file binary, so
// there is nowhere shared to put it (same reason arg() is duplicated).
//
// Call it only once the window's SIZE IS FINAL — centring a window that is
// still going to lay itself out leaves it off-centre by half the growth.
//
// NSScreen.main, not NSWindow.center(): center() uses the screen holding most of
// the window, and an un-positioned window can sit on a display the user is not
// working on — it would then be centred there. .main is the screen with the
// active window. The 0.75 factor reproduces center()'s placement (the gap above
// is a third of the gap below), so dialogs sit where macOS users expect.
func centerOnActiveScreen(_ w: NSWindow) {
    guard let vis = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
        w.center(); return
    }
    let f = w.frame
    let x = vis.minX + (vis.width  - f.width)  / 2
    let y = vis.minY + (vis.height - f.height) * 0.75
    w.setFrameOrigin(NSPoint(x: max(vis.minX, x), y: max(vis.minY, y)))
}

final class ProgressController: NSObject, NSApplicationDelegate {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 168),
        styleMask: [.titled], backing: .buffered, defer: false)
    let status = NSTextField(labelWithString: "Preparing Beyond All Reason…")
    let detail = NSTextField(labelWithString: "")
    var bar = NSProgressIndicator()
    let quit = NSButton(title: "Quit", target: nil, action: nil)
    let skip = NSButton(title: "Skip update", target: nil, action: nil)
    var inError = false
    var shownAt = Date()

    func applicationDidFinishLaunching(_ n: Notification) {
        window.title = "BAR Launcher"
        centerOnActiveScreen(window)   // fixed contentRect: size is already final
        window.isReleasedWhenClosed = false

        status.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        status.frame = NSRect(x: 20, y: 118, width: 440, height: 22)
        detail.font = NSFont.systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 20, y: 92, width: 440, height: 18)
        detail.lineBreakMode = .byTruncatingMiddle

        bar.frame = NSRect(x: 20, y: 58, width: 440, height: 20)
        bar.isIndeterminate = true
        bar.style = .bar
        bar.startAnimation(nil)

        quit.frame = NSRect(x: 380, y: 16, width: 80, height: 28)
        quit.bezelStyle = .rounded
        quit.target = self
        quit.action = #selector(doQuit)
        quit.isHidden = true

        // Skip: lets a user on half-working wifi (train/plane) play NOW on the
        // content they already have — the launcher rolls the update back.
        // NEVER the default button: Enter must not skip an update, and it must
        // not steal focus (space would press a focused button).
        skip.frame = NSRect(x: 20, y: 16, width: 120, height: 28)
        skip.bezelStyle = .rounded
        skip.target = self
        skip.action = #selector(doSkip)
        skip.keyEquivalent = ""
        skip.refusesFirstResponder = true
        skip.isHidden = (skipFilePath == nil)

        let cv = window.contentView!
        cv.addSubview(status); cv.addSubview(detail); cv.addSubview(bar)
        cv.addSubview(quit); cv.addSubview(skip)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        shownAt = Date()

        readStdin()
    }

    @objc func doQuit() { NSApp.terminate(nil) }

    // Swap in a brand-new indicator when changing mode. Toggling
    // isIndeterminate on a live bar leaves the indeterminate bounce
    // animation running on this macOS regardless of stopAnimation order —
    // observed as a blue segment bouncing across a bar that was receiving
    // real percentages. A fresh view cannot inherit stale animation state.
    func replaceBar(indeterminate: Bool) {
        let f = bar.frame
        let wasHidden = bar.isHidden
        bar.stopAnimation(nil)
        bar.removeFromSuperview()
        bar = NSProgressIndicator()
        bar.frame = f
        bar.style = .bar
        bar.isIndeterminate = indeterminate
        bar.minValue = 0; bar.maxValue = 100
        bar.isHidden = wasHidden
        window.contentView?.addSubview(bar)
        if indeterminate { bar.startAnimation(nil) }
    }

    @objc func doSkip() {
        guard let p = skipFilePath else { return }
        FileManager.default.createFile(atPath: p, contents: nil)
        skip.isEnabled = false
        skip.title = "Skipping…"
    }

    func readStdin() {
        let fh = FileHandle.standardInput
        DispatchQueue.global(qos: .userInitiated).async {
            var buf = Data()
            while true {
                let chunk = fh.availableData
                if chunk.isEmpty { break }              // EOF
                buf.append(chunk)
                while let nl = buf.firstIndex(of: 0x0a) {
                    let line = String(data: buf[..<nl], encoding: .utf8) ?? ""
                    buf.removeSubrange(...nl)
                    DispatchQueue.main.async { self.handle(line) }
                }
            }
            DispatchQueue.main.async {
                guard !self.inError else { return }        // error stays until Quit
                // success closes — but only after MIN_DISPLAY on screen
                let remaining = MIN_DISPLAY - Date().timeIntervalSince(self.shownAt)
                if remaining <= 0 {
                    NSApp.terminate(nil)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                        if !self.inError { NSApp.terminate(nil) }
                    }
                }
            }
        }
    }

    func handle(_ line: String) {
        guard let tag = line.first else { return }
        let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        switch tag {
        case "S": status.stringValue = rest
        case "D": detail.stringValue = rest
        case "P":
            if let v = Int(rest) {
                if bar.isIndeterminate { replaceBar(indeterminate: false) }
                bar.doubleValue = Double(max(0, min(100, v)))
            }
        case "I":
            if !bar.isIndeterminate { replaceBar(indeterminate: true) }
            else { bar.startAnimation(nil) }
        case "F":
            status.stringValue = rest
            bar.stopAnimation(nil)
            bar.isHidden = true
            skip.isHidden = true
        case "E":
            inError = true
            skip.isHidden = true      // error state: Quit is the only action
            bar.isIndeterminate = false
            bar.stopAnimation(nil)
            bar.isHidden = true
            status.stringValue = "Setup could not complete"
            status.textColor = .systemRed
            detail.stringValue = rest
            detail.textColor = .labelColor
            detail.frame = NSRect(x: 20, y: 52, width: 440, height: 54)
            detail.maximumNumberOfLines = 3
            detail.lineBreakMode = .byWordWrapping
            quit.isHidden = false
        default: break
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no second dock icon; window still shows
let c = ProgressController()
app.delegate = c
app.run()
