#!/bin/bash
# JTDX-VU: a FlexRadio that does not answer a key-up (the 6600, 2026-10-21: no
# reply to "xmit 1" within 1 s, JTDX-VU dropped the link, the reconnect came up
# on the default 14.100 slice and called CQ there). A throwaway "-r flexkm" copy
# on 21.074 calls CQ against tools/fake_flex.py with FAKE_GUI_SLICE=1 (every new
# client gets a slice at 14.100) and FAKE_XMIT_MISS=$MISS (the first MISS
# key-ups are never answered).
# Expected: MISS=1 or 2 - no reconnect, the missed overs are skipped and a later
# one keys, all on 21.074; MISS=3 - one reconnect, back on 21.074 (never Tx on
# 14.100), and a later over keys.
# usage: [MISS=1] [HOLD=120] [BIN=.../jtdx] tools/flex_keymiss_test.sh
set -u
MISS=${MISS:-1}
S=${S:-$(mktemp -d /tmp/jtdxvu-test.XXXXXX)}; J="$(cd "$(dirname "$0")/.." && pwd)"
BIN=${BIN:-$J/build/bundle/JTDX-VU.app/Contents/MacOS/jtdx}
INI="$HOME/Library/Preferences/JTDX-VU - flexkm.ini"
APP="$HOME/Library/Application Support/JTDX-VU - flexkm"
[ -e "$INI" ] && { echo "flexkm ini exists - stopped"; exit 1; }
lsof -nP -iTCP:4994 -sTCP:LISTEN >/dev/null 2>&1 && { echo "port 4994 in use - stopped"; exit 1; }
FAKE_GUI_SLICE=1 FAKE_XMIT_MISS=$MISS python3 "$J/tools/fake_flex.py" --port 4994 --forever --wait 1 --log "$S/fake_flex.txt" --txdir "$S/tx" > "$S/fake.log" 2>&1 &
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
CATTCIPort=127.0.0.1:4994
TCIAudio=true
Polling=1
UDPServer=127.0.0.1
UDPServerPort=2301
UDP2ServerPort=2291
AcceptUDPRequests=true
EnableTCPConnection=false
CheckForUpdates=false
INI
BEFORE=$(ipcs -m | awk '$5=="manoj"{print $2}' | sort)
"$BIN" -r flexkm > "$S/app.log" 2>&1 &
P=$!
sleep ${SETTLE:-15}
python3 "$J/tools/udp_ctl.py" 2301 cq sleep=${HOLD:-120} halt > "$S/udp.txt" 2>&1
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P)
    click menu item \"Quit JTDX-VU\" of menu 1 of menu bar item 2 of menu bar 1
  end tell" >/dev/null 2>&1
for i in $(seq 1 20); do kill -0 $P 2>/dev/null || break; sleep 0.5; done
kill $P 2>/dev/null; sleep 1; kill -9 $P 2>/dev/null
for q in $(pgrep -f "jtdxjt9 -s JTDX-VU - flexkm"); do kill $q; done
kill $FAKE 2>/dev/null
for m in $(comm -13 <(echo "$BEFORE") <(ipcs -m | awk '$5=="manoj"{print $2}' | sort)); do ipcrm -m $m 2>/dev/null; done
cp "$APP"/flex_trace.txt "$APP"/*ALL.TXT "$S/" 2>/dev/null
rm -f "$INI"; rm -rf "$APP"
echo "== radio saw (tunes, key-ups)"
grep -E -- 'slice tune|xmit|client gui' "$S/fake_flex.txt" | sed 's/^\([0-9]*\.[0-9]\{3\}\)[0-9]*/\1/' | cut -c1-110
echo "== JTDX-VU"
grep -h -E "======== start|not confirmed|applying after start|poll -> error" "$S/flex_trace.txt" | cut -c1-120
grep -h -E " MHz " "$S"/*ALL.TXT | cut -c1-80
echo "starts: $(grep -c '======== start' "$S/flex_trace.txt" 2>/dev/null)"
echo "logs in $S"
