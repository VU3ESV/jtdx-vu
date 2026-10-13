#!/bin/bash
# JTDX-VU issue #4: a FlexRadio link that drops and comes back inside one run.
# A throwaway "-r flexrc" copy starts on 21.074 against tools/fake_flex.py with
# FAKE_GUI_SLICE=1 (every new client is handed a slice at 14.100, as the 6600
# does). After UP s the fake radio is killed (MODE=kill: the control link
# closes) or its audio stopped (MODE=mute: link up, DAX gone - the VPN blackhole
# case), then brought back after DOWN s; the run ends HOLD s later. Prints
# every slice tune the radio saw and how many times the client started.
# usage: [MODE=kill|mute] tools/flex_reconnect_test.sh <jtdx binary>
set -u
BIN=$1; MODE=${MODE:-kill}
S=${S:-$(mktemp -d /tmp/jtdxvu-test.XXXXXX)}; J="$(cd "$(dirname "$0")/.." && pwd)"
INI="$HOME/Library/Preferences/JTDX-VU - flexrc.ini"
APP="$HOME/Library/Application Support/JTDX-VU - flexrc"
[ -e "$INI" ] && { echo "flexrc ini exists - stopped"; exit 1; }
lsof -nP -iTCP:4992 -sTCP:LISTEN >/dev/null 2>&1 && { echo "port 4992 in use - stopped"; exit 1; }
fake() { FAKE_GUI_SLICE=1 python3 "$J/tools/fake_flex.py" --forever --wait 1 --log "$S/fake_flex.txt" --txdir "$S" > "$S/fake$1.log" 2>&1 & FAKE=$!; }
fake 1; sleep 2
cat > "$INI" <<INI
[Common]
Mode=FT8
DialFreq=21074000
[Configuration]
MyCall=VU2CPL
MyGrid=MK83te
Rig=FlexRadio VITA-49 Slice A
PTTMethod=@Variant(\0\0\0\x7f\0\0\0\x1eTransceiverFactory::PTTMethod\0\0\0\0\xfPTT_method_CAT\0)
CATTCIPort=127.0.0.1:4992
TCIAudio=true
Polling=1
UDPServer=127.0.0.1
UDPServerPort=2299
UDP2ServerPort=2298
AcceptUDPRequests=false
EnableTCPConnection=false
CheckForUpdates=false
INI
BEFORE=$(ipcs -m | awk '$5=="manoj"{print $2}' | sort)
"$BIN" -r flexrc > "$S/app.log" 2>&1 &
P=$!
sleep ${UP:-20}
echo "$(date +%s.%N) ---- link down ($MODE)" >> "$S/fake_flex.txt"
if [ "$MODE" = kill ]; then kill $FAKE; sleep ${DOWN:-30}; fake 2
else kill -STOP $FAKE; sleep ${DOWN:-30}; kill -CONT $FAKE; fi
echo "$(date +%s.%N) ---- link up" >> "$S/fake_flex.txt"
sleep ${HOLD:-40}
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $P)
    click menu item \"Quit JTDX-VU\" of menu 1 of menu bar item 2 of menu bar 1
  end tell" >/dev/null 2>&1
for i in $(seq 1 20); do kill -0 $P 2>/dev/null || break; sleep 0.5; done
kill $P 2>/dev/null; sleep 1; kill -9 $P 2>/dev/null
for q in $(pgrep -f "jtdxjt9 -s JTDX-VU - flexrc"); do kill $q; done
kill $FAKE 2>/dev/null
for m in $(comm -13 <(echo "$BEFORE") <(ipcs -m | awk '$5=="manoj"{print $2}' | sort)); do ipcrm -m $m 2>/dev/null; done
cp "$APP"/flex_trace.txt "$S/" 2>/dev/null
rm -f "$INI"; rm -rf "$APP"
grep -E -- '----|slice tune|client gui' "$S/fake_flex.txt" | sed 's/^\([0-9]*\.[0-9]\{3\}\)[0-9]*/\1/'
echo "starts: $(grep -c '======== start' "$S/flex_trace.txt" 2>/dev/null)"
echo "logs in $S"
