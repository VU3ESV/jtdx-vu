#!/bin/bash
# JTDX-VU: 160m crossband with India (Misc > Crossband 160m operation with
# India). With Split = Fake It, a VU station on dial 1.840 must transmit on
# 1.808 and anyone else on dial 1.808 must transmit on 1.840 (audio offset on
# top). Runs a throwaway "-r xbandtest" copy on tools/fake_tci.py, moves the
# fake radio to DIAL, calls CQ for one over and prints the vfo commands sent.
# usage: MYCALL=VU2CPL DIAL=1840000 [BIN=.../jtdx] tools/crossband_vu_test.sh
#        MYCALL=K1ABC  DIAL=1808000 ...
set -u
S=${S:-$(mktemp -d /tmp/jtdxvu-test.XXXXXX)}; mkdir -p "$S"; J="$(cd "$(dirname "$0")/.." && pwd)"
BIN=${BIN:-$J/build/bundle/JTDX-VU.app/Contents/MacOS/jtdx}
INI="$HOME/Library/Preferences/JTDX-VU - xbandtest.ini"
APP="$HOME/Library/Application Support/JTDX-VU - xbandtest"
PORT=50093
[ -e "$INI" ] && { echo "xbandtest ini exists - stopped"; exit 1; }
python3 "$J/tools/fake_tci.py" "$S/fake.log" $PORT > /dev/null 2>&1 &
SIM=$!
sleep 2
cat > "$INI" <<INI
[Common]
Mode=FT8
Crossband160mVU=true
RxFreq=1500
TxFreq=1500
[Configuration]
MyCall=${MYCALL:-VU2CPL}
MyGrid=MK83te
Rig=TCI Client RX1
PTTMethod=@Variant(\0\0\0\x7f\0\0\0\x1eTransceiverFactory::PTTMethod\0\0\0\0\xfPTT_method_CAT\0)
CATTCIPort=127.0.0.1:$PORT
TCIAudio=true
Polling=1
UDPServer=127.0.0.1
UDPServerPort=2259
UDP2ServerPort=2258
AcceptUDPRequests=true
EnableTCPConnection=false
CheckForUpdates=false
SplitMode=@Variant(\\0\\0\\0\\x7f\\0\\0\\0\\x1eTransceiverFactory::SplitMode\\0\\0\\0\\0\\x13split_mode_emulate\\0)
INI
BEFORE=$(ipcs -m | awk '$5=="manoj"{print $2}' | sort)
"$BIN" -r xbandtest > "$S/app.log" 2>&1 &
P=$!
sleep 15
echo "vfo:0,0,${DIAL:-1840000};" > "$S/fake.log.push"; sleep 4
python3 "$J/tools/udp_ctl.py" 2259 cq sleep=${HOLD:-25} halt > "$S/udp.txt" 2>&1
sleep 3
kill $P; sleep 3; kill -9 $P 2>/dev/null
for q in $(pgrep -f "jtdxjt9 -s JTDX-VU - xbandtest"); do kill $q; done
kill $SIM 2>/dev/null
sleep 1
for m in $(comm -13 <(echo "$BEFORE") <(ipcs -m | awk '$5=="manoj"{print $2}' | sort)); do ipcrm -m $m 2>/dev/null; done
rm -f "$INI"; rm -rf "$APP"
grep -E "pushed|< vfo:0,[01],[0-9]|< trx:0,true|TX over" "$S/fake.log" | head -20
echo "logs in $S"
