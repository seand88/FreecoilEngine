// Recoil Engine — user dialogs for the BAR launcher.
//
// Two modes:
//   (default)        first-run consent, shown once before anything downloads:
//                    the launcher is about to fetch a game (Beyond All Reason)
//                    from a third-party content network and the user must opt
//                    in. "Quit" is the default (Return) so the safe choice is
//                    the effortless one.
//                    Usage: consent-dialog --server <host>
//                    Exit: 0 = "Accept Risk and Run", 1 = "Quit"/closed.
//   --notice <text>  informational notice (e.g. online play disabled), single
//                    OK button. Exit: always 0.
import AppKit

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return nil
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

// Run an alert reliably in FRONT of every other app. activate() alone races
// (focus may sit on another app when this separate process launches), so also
// raise the panel above normal windows and let it show on the active Space
// (even over a fullscreen game). Used for both the notice and the gate.
// BAR app icon instead of the generic executable/folder icon.
func barIcon() -> NSImage? {
    if let p = ProcessInfo.processInfo.environment["BAR_ICON_PATH"],
       let i = NSImage(contentsOfFile: p) { return i }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return NSImage(contentsOf: exe.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/AppIcon.icns"))
}

// Centre a window on the ACTIVE screen. Duplicated verbatim in the launcher's
// other Swift helpers: each is compiled as a standalone single-file binary, so
// there is nowhere shared to put it (same reason arg() is duplicated).
//
// Call it only once the window's SIZE IS FINAL — see the alert.layout() note in
// present() below.
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

func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
    if let icon = barIcon() { alert.icon = icon }
    // SIZE BEFORE POSITION. An NSAlert window is only 260pt wide until it lays
    // itself out; runModal() does that on show, growing it right/up from a fixed
    // origin. Centring first therefore left both dialogs ~150pt right of centre
    // (reported 2026-07-24, measured on a 2560pt display). layout() makes the
    // size final now, so the centring below is the one the user sees.
    alert.layout()
    let w = alert.window
    w.level = .floating
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    // position BEFORE ordering front: we show the window ahead of runModal (to
    // beat other apps' focus), so runModal never gets to position it — without
    // this it appears at the frame's default origin (off to the left).
    centerOnActiveScreen(w)
    w.makeKeyAndOrderFront(nil)
    w.orderFrontRegardless()
    app.activate(ignoringOtherApps: true)
    return alert.runModal()
}

let alert = NSAlert()
alert.messageText = "Recoil Engine"

if let notice = arg("--notice") {
    alert.informativeText = notice
    alert.alertStyle = .informational
    // right-aligned signature below the message (true bottom-right, not
    // spaces). NSAlert lays the accessory across its full text column (~500pt
    // wide for this message), so a full-width right-aligned label sits at the
    // right edge; .width autoresizing keeps it flush if the alert resizes.
    let sig = NSTextField(labelWithString: "— Ben")
    sig.alignment = .right
    sig.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    sig.textColor = .secondaryLabelColor
    sig.frame = NSRect(x: 0, y: 0, width: 500, height: 18)
    sig.autoresizingMask = [.width]
    alert.accessoryView = sig
    alert.addButton(withTitle: "OK")
    _ = present(alert)
    exit(0)
}

let server = arg("--server") ?? "the BAR content network"
alert.informativeText =
    "Do you wish to download and run the game Beyond All Reason from \(server)?\n\n" +
    "Beyond All Reason is third-party content. It is not hosted, vetted, or " +
    "endorsed by the maintainer of Recoil Engine for macOS, who accepts no " +
    "responsibility for it or for any damage it may cause. Download and run " +
    "this game AT YOUR OWN RISK!\n\n" +
    "If you continue, future updates for the game may download and run " +
    "automatically."
alert.alertStyle = .warning
// first button = default (Return). Quit is the safe default.
alert.addButton(withTitle: "Quit")
alert.addButton(withTitle: "Accept Risk and Run")

let response = present(alert)
exit(response == .alertSecondButtonReturn ? 0 : 1)
