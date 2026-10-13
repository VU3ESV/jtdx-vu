#!/bin/bash
# JTDX-VU: decode-window check without a radio - a throwaway "-r aligntest" copy
# fed by tools/fake_tci.py playing WAVS (one per UTC 15 s period), screenshot of
# the main window after HOLD s (default 55). EXTRA_INI lines are appended to the
# test ini (e.g. "[Switcher]\nNewOnly=1"); LOGADI is copied in as the log.
# usage: WAVS="a.wav b.wav" tools/decode_window_test.sh <jtdx binary> <tag> <font string>
# Runs a throwaway "-r aligntest" JTDX-VU on fake TCI playing busy FT8 recordings,
# screenshots the main window after 3 periods, then cleans everything up.
set -u
BIN=$1; TAG=$2; FONT=$3
S=${S:-$(mktemp -d /tmp/jtdxvu-test.XXXXXX)}; J="$(cd "$(dirname "$0")/.." && pwd)"
INI="$HOME/Library/Preferences/JTDX-VU - aligntest.ini"
APP="$HOME/Library/Application Support/JTDX-VU - aligntest"
PORT=50097
[ -e "$INI" ] && { echo "aligntest ini exists - stopped"; exit 1; }
W="${WAVS:-}"; [ -n "$W" ] || { echo "set WAVS=\"a.wav b.wav\" (15 s 12 kHz FT8 recordings)"; exit 1; }
FAKE_TCI_WAVS="$W" python3 "$J/tools/fake_tci.py" "$S/fake_$TAG.log" $PORT > /dev/null 2>&1 &
SIM=$!
sleep 4
cat > "$INI" <<INI
[Common]
Mode=FT8
[Configuration]
MyCall=VU2CPL
MyGrid=MK83te
Rig=TCI Client RX1
PTTMethod=@Variant(\0\0\0\x7f\0\0\0\x1eTransceiverFactory::PTTMethod\0\0\0\0\xfPTT_method_CAT\0)
CATTCIPort=127.0.0.1:$PORT
TCIAudio=true
Polling=1
UDPServer=127.0.0.1
UDPServerPort=2299
UDP2ServerPort=2298
AcceptUDPRequests=false
EnableTCPConnection=false
countryName=true
ShowUSState=true
DecodedTextFont="$FONT"
CheckForUpdates=false
INI
[ -n "${EXTRA_INI:-}" ] && printf "%b\n" "$EXTRA_INI" >> "$INI"
if [ -n "${LOGADI:-}" ]; then mkdir -p "$APP"; cp "$LOGADI" "$APP/wsjtx_log.adi"; fi
BEFORE=$(ipcs -m | awk '$5=="manoj"{print $2}' | sort)
"$BIN" -r aligntest > "$S/app_$TAG.log" 2>&1 &
P=$!
sleep ${HOLD:-55}
WID=$(swift "$J/tools/macos-window-id.swift" $P | head -1)
[ -n "$WID" ] && screencapture -x -o -l "$WID" "$S/shot_$TAG.png"
echo "pid=$P wid=$WID"
kill $P; sleep 3; kill -9 $P 2>/dev/null
for q in $(pgrep -f "jtdxjt9 -s JTDX-VU - aligntest"); do kill $q; done
kill $SIM 2>/dev/null
sleep 1
for m in $(comm -13 <(echo "$BEFORE") <(ipcs -m | awk '$5=="manoj"{print $2}' | sort)); do ipcrm -m $m 2>/dev/null && echo "removed shm $m"; done
rm -f "$INI"; rm -rf "$APP" "$HOME/Library/Application Support/JTDX-VU - aligntest"
ls -la "$S/shot_$TAG.png" 2>/dev/null
