#!/bin/bash
# JTDX-VU: the computer's address changes in the middle of an over (2026-10-21:
# the Mac mini's cable moved ports; the unkey went out from the old address and
# the FLEX-6600 stayed in TX ~53 s until it was restarted). A throwaway
# "-r flexst" copy calls CQ against tools/fake_flex.py with FAKE_FREEZE_KEYED=1:
# the session that first keys becomes a dead peer - its unkey and its close never
# arrive, and the fake holds it keyed until "client disconnect" (or 120 s).
# Expected: the no-audio watchdog reconnects, the new session closes the old one
# ("our previous session ... closed it"), the fake logs "TX released" within
# ~20 s of the key-up, and the reconnect is back on 21.074.
# usage: [HOLD=90] [BIN=.../jtdx] tools/flex_stale_tx_test.sh
set -u
S=${S:-$(mktemp -d /tmp/jtdxvu-test.XXXXXX)}; J="$(cd "$(dirname "$0")/.." && pwd)"
BIN=${BIN:-$J/build/bundle/JTDX-VU.app/Contents/MacOS/jtdx}
INI="$HOME/Library/Preferences/JTDX-VU - flexst.ini"
APP="$HOME/Library/Application Support/JTDX-VU - flexst"
[ -e "$INI" ] && { echo "flexst ini exists - stopped"; exit 1; }
lsof -nP -iTCP:4995 -sTCP:LISTEN >/dev/null 2>&1 && { echo "port 4995 in use - stopped"; exit 1; }
FAKE_GUI_SLICE=1 FAKE_FREEZE_KEYED=1 python3 "$J/tools/fake_flex.py" --port 4995 --forever --wait 1 --log "$S/fake_flex.txt" --txdir "$S/tx" > "$S/fake.log" 2>&1 &
FAKE=$!; sleep 2
cat > "$INI" <<INI
[Common]
Mode=FT8
DialFreq=21074000
[Configuration]
MyCall=VU2CPL
MyGrid=MK83te
Rig=FlexRadio VITA-49 Slice A
PTTMethod=@Variant(\0\0\0\x7f\0\0\0\x1eTransceiverFactory::PTTMethod\0\0\0\0\xfPTT_method_CAT\0)
CATTCIPort=127.0.0.1:4995
TCIAudio=true
Polling=1
UDPServer=127.0.0.1
UDPServerPort=2303
UDP2ServerPort=2293
AcceptUDPRequests=true
EnableTCPConnection=false
CheckForUpdates=false
INI
BEFORE=$(ipcs -m | awk '$5=="manoj"{print $2}' | sort)
"$BIN" -r flexst > "$S/app.log" 2>&1 &
P=$!
sleep ${SETTLE:-15}
python3 "$J/tools/udp_ctl.py" 2303 cq sleep=${HOLD:-90} halt > "$S/udp.txt" 2>&1
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P)
    click menu item \"Quit JTDX-VU\" of menu 1 of menu bar item 2 of menu bar 1
  end tell" >/dev/null 2>&1
for i in $(seq 1 20); do kill -0 $P 2>/dev/null || break; sleep 0.5; done
kill $P 2>/dev/null; sleep 1; kill -9 $P 2>/dev/null
for q in $(pgrep -f "jtdxjt9 -s JTDX-VU - flexst"); do kill $q; done
kill $FAKE 2>/dev/null
for m in $(comm -13 <(echo "$BEFORE") <(ipcs -m | awk '$5=="manoj"{print $2}' | sort)); do ipcrm -m $m 2>/dev/null; done
cp "$APP"/flex_trace.txt "$APP"/*ALL.TXT "$S/" 2>/dev/null
rm -f "$INI"; rm -rf "$APP"
echo "== radio saw (tunes, key-ups)"
grep -E -- 'slice tune|xmit|client gui|frozen|disconnect|TX released' "$S/fake_flex.txt" | sed 's/^\([0-9]*\.[0-9]\{3\}\)[0-9]*/\1/' | cut -c1-110
echo "== JTDX-VU"
grep -h -E "======== start|not confirmed|applying after start|poll -> error|previous session" "$S/flex_trace.txt" | cut -c1-120
grep -h -E " MHz " "$S"/*ALL.TXT | cut -c1-80
echo "starts: $(grep -c '======== start' "$S/flex_trace.txt" 2>/dev/null)"
echo "logs in $S"
