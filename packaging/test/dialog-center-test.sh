#!/bin/bash
# dialog-center-test.sh — geometry harness for the launcher's Swift dialogs.
#
# Every dialog the user meets before the game starts must appear centred on the
# screen they are actually looking at. This builds each helper FROM SOURCE, shows
# it for real, and measures where the window landed (CGWindowList), asserting it
# is centred on the active screen's visibleFrame.
#
# The bug this exists for (2026-07-24): consent-dialog centred its NSAlert BEFORE
# the alert had laid itself out. An un-laid-out alert window is ~260pt wide;
# runModal() then grows it to ~520pt to the RIGHT of a fixed origin, landing the
# "online play disabled" and download-consent dialogs ~130pt right of centre,
# while the message-check panel (which sizes itself first) looked correct.
#
# NB this test SHOWS REAL WINDOWS and takes focus for a second at a time — it
# needs a logged-in GUI session (it skips cleanly without one), and you should
# not be typing elsewhere while it runs.
set -uo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'pkill -f "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM

pass=0; fail=0
ok()  { pass=$((pass+1)); printf "  ok   %s\n" "$1"; }
bad() { fail=$((fail+1)); printf "  FAIL %s\n" "$1"; [ -n "${2:-}" ] && printf "       %s\n" "$2"; }

# ---- probe: where did the window actually land? ------------------------------
# Reports the largest on-screen window of a pid as "OFFSET <dx> <dy>", the
# distance from the centring the helpers aim for. Bounds need no screen-recording
# permission (unlike window titles or images), so this runs unattended.
cat > "$WORK/probe.swift" <<'EOF'
import AppKit
// no pid => report how many screens AppKit can see (0 = nothing to measure on).
// NB "launchctl managername" is NOT the test for this: an agent/CI shell reports
// "Background" while AppKit still reaches the logged-in user's window server.
guard CommandLine.arguments.count > 1 else { print(NSScreen.screens.count); exit(0) }
let pid = Int32(CommandLine.arguments[1])!
guard let vis = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame,
      let zero = NSScreen.screens.first else { print("OFFSET nan nan"); exit(1) }
var best: CGRect? = nil
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                      kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    guard (w[kCGWindowOwnerPID as String] as? Int32) == pid,
          let b = w[kCGWindowBounds as String] as? [String: CGFloat],
          let x = b["X"], let y = b["Y"], let ww = b["Width"], let hh = b["Height"],
          ww > 100, hh > 60 else { continue }
    let r = CGRect(x: x, y: y, width: ww, height: hh)
    if best == nil || r.width * r.height > best!.width * best!.height { best = r }
}
guard let r = best else { print("OFFSET nowindow nowindow"); exit(1) }
let akY = zero.frame.height - (r.origin.y + r.height)   // CG top-left -> AppKit bottom-left
let dx = (r.origin.x + r.width/2) - vis.midX
let dy = akY - (vis.minY + (vis.height - r.height) * 0.75)
print(String(format: "OFFSET %.0f %.0f", dx, dy))
EOF
swiftc -O -o "$WORK/probe" "$WORK/probe.swift" 2>/dev/null || { echo "FATAL: probe would not build"; exit 1; }

if [ "$("$WORK/probe" 2>/dev/null)" = "0" ]; then
  echo "SKIP: no screens (dialog geometry cannot be measured headless)"
  exit 0
fi

for h in consent-dialog progress-window error-dialog message-check; do
  swiftc -O -o "$WORK/$h" "$PKG/$h.swift" 2>/dev/null \
    || { echo "FATAL: $h.swift would not build"; exit 1; }
done

# minimal config so message-check has something to show
cat > "$WORK/msg.json" <<'JSON'
{ "schema":1, "messages":[
  { "id":"center-test", "date":"2026-07-24", "target":{"op":"all"},
    "title":"Centering Test",
    "body":["<p>A message long enough to force the panel to size itself before it is shown.</p>"],
    "frequency":"always",
    "buttons":[{"label":"Continue","action":"continue","default":true}] } ] }
JSON

# check <name> <command...> — show it, measure it, kill it
check() {
  local name="$1"; shift
  "$@" >/dev/null 2>&1 &
  local pid=$! out="" i
  for i in 1 2 3 4 5 6 7 8 9 10; do          # wait for the window to exist
    sleep 0.4
    out=$("$WORK/probe" "$pid" 2>/dev/null)
    case "$out" in OFFSET\ nowindow*) ;; OFFSET*) break;; esac
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  set -- $out
  if [ "${2:-}" = "nowindow" ] || [ -z "${2:-}" ]; then
    bad "$name: no window appeared"; return
  fi
  # 2pt of slack absorbs half-point rounding on Retina; anything more is visible
  if [ "${2#-}" -le 2 ] && [ "${3#-}" -le 3 ]; then
    ok "$name centred on the active screen (dx=$2 dy=$3)"
  else
    bad "$name off-centre" "dx=$2 dy=$3 (want |dx|<=2, |dy|<=3)"
  fi
}

echo "== consent dialogs (the reported bug: NSAlert sized after being centred) =="
check "download consent" "$WORK/consent-dialog" --server "repos-cdn.beyondallreason.dev"
check "online-disabled notice" "$WORK/consent-dialog" --notice "ONLINE PLAY IS DISABLED in this build while I seek approval from the creators of Beyond All Reason to connect to their community servers.

The game opens on a sign-in screen first — press Cancel to reach everything that works offline: skirmish against AI, replays, and local-network (LAN) games."

echo "== the other pre-game windows =="
check "error dialog" "$WORK/error-dialog" --title "BAR Launcher" \
      --message "[network] Could not reach the content servers."
check "remote message" "$WORK/message-check" --config-url "file://$WORK/msg.json" \
      --app-version 0.12 --seen-file "$WORK/seen.json"

# progress-window reads its protocol on stdin and closes at EOF
mkfifo "$WORK/pw.fifo"
"$WORK/progress-window" < "$WORK/pw.fifo" >/dev/null 2>&1 &
PWPID=$!
exec 3> "$WORK/pw.fifo"; printf 'S Preparing Beyond All Reason (first run)…\n' >&3
sleep 1.2
OUT=$("$WORK/probe" "$PWPID" 2>/dev/null)
exec 3>&-; kill "$PWPID" 2>/dev/null; wait "$PWPID" 2>/dev/null
set -- $OUT
if [ "${2:-nowindow}" != "nowindow" ] && [ "${2#-}" -le 2 ] && [ "${3#-}" -le 3 ]; then
  ok "progress window centred on the active screen (dx=$2 dy=$3)"
else
  bad "progress window off-centre" "dx=${2:-?} dy=${3:-?}"
fi

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
