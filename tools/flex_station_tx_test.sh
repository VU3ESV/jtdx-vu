#!/bin/bash
# JTDX-VU: four copies on one fake FlexRadio that keeps ONE dax_tx stream per
# station, as a real radio (tools/fake_flex.py, FAKE_STATION_TX=1, 2-GUI-client
# limit). flexa and flexb become GUI clients with their own TX streams; flexc and
# flexd are refused, join a station, have their own dax_tx refused and must send
# on the station's stream. Each copy in turn is made to call CQ over UDP; the
# fake logs every transmission with the stream it came on (KK4CDK, 2026-10-18).
# Throwaway -r flexa..flexd profiles, removed afterwards.
# macOS: the bundle; Linux: BIN=build/jtdx under Xvfb (DISPLAY=:7 started if unset).
# NODAX_A=1: flexa runs without DAX audio, so its station has no dax_tx stream and
# flexc makes the station's stream and flexd, finding it under flexc's handle, warns
# "no DAX TX stream" on the status bar (flexa is not keyed).
# usage: [BIN=.../jtdx] [HOLD=45] [SETTLE=15] [NODAX_A=1] tools/flex_station_tx_test.sh
S=${S:-$(mktemp -d /tmp/jtdxvu-test.XXXXXX)}; J="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(uname)" = Darwin ]; then
  BIN=${BIN:-$J/build/bundle/JTDX-VU.app/Contents/MacOS/jtdx}
  INI() { echo "$HOME/Library/Preferences/JTDX-VU - $1.ini"; }
  DATA() { echo "$HOME/Library/Application Support/JTDX-VU - $1"; }
else
  BIN=${BIN:-$J/build/jtdx}
  INI() { echo "$HOME/.config/JTDX-VU - $1.ini"; }
  DATA() { echo "$HOME/.local/share/JTDX-VU - $1"; }
  if [ -z "$DISPLAY" ]; then export DISPLAY=:7; pgrep -f "Xvfb :[7]" >/dev/null || { Xvfb :7 -screen 0 1600x1000x24 >$S/xvfb.log 2>&1 & sleep 2; }; fi
fi
COPIES="flexa:A:2299:2289 flexb:A:2297:2287 flexc:B:2295:2285 flexd:C:2293:2283"
for spec in $COPIES; do n=${spec%%:*}; [ -e "$(INI $n)" ] && { echo "$n ini exists"; exit 1; }; done
pgrep -f "fake_flex.py --port 4993" >/dev/null && { echo "fake running"; exit 1; }
(cd $S && FAKE_STATION_TX=1 python3 $J/tools/fake_flex.py --port 4993 --log $S/ff_station.log --txdir $S/tx --wait 1 --forever > $S/ff_station.out 2>&1 &); sleep 2
for spec in $COPIES; do IFS=: read n L u1 u2 <<< "$spec"
cat > "$(INI $n)" <<INI
[Common]
Mode=FT8
[Configuration]
MyCall=VU2CPL
MyGrid=MK83te
Rig=FlexRadio VITA-49 Slice $L
PTTMethod=@Variant(\0\0\0\x7f\0\0\0\x1eTransceiverFactory::PTTMethod\0\0\0\0\xfPTT_method_CAT\0)
CATTCIPort=127.0.0.1:4993
TCIAudio=$( [ -n "$NODAX_A" ] && [ $n = flexa ] && echo false || echo true )
Polling=1
UDPServer=127.0.0.1
UDPServerPort=$u1
UDP2ServerPort=$u2
AcceptUDPRequests=true
EnableTCPConnection=false
CheckForUpdates=false
INI
("$BIN" -r $n > $S/app_$n.log 2>&1 &); sleep 6; done
sleep ${SETTLE:-15}
# one copy at a time: CQ, hold it through a transmission, halt
for spec in $COPIES; do IFS=: read n L u1 u2 <<< "$spec"
  [ -n "$NODAX_A" ] && [ $n = flexa ] && continue     # no sound card to key it with here
  echo "== CQ from $n"; python3 $J/tools/udp_ctl.py $u1 cq sleep=${HOLD:-45} halt > $S/udp_$n.txt 2>&1 &
  sleep $(( ${HOLD:-45} - 5 ))     # Linux: the screen near the end, the status bar of the top window
  [ "$(uname)" != Darwin ] && command -v import >/dev/null && import -window root $S/screen_$n.png; wait; sleep 3; done
for spec in $COPIES; do n=${spec%%:*}; echo "== $n"
  grep -h -E "======== start|refused|joined GUI client|dax_tx|DAX TX|no DAX TX|start failed|do_ptt 1" "$(DATA $n)/flex_trace.txt" 2>/dev/null | tail -8 | cut -c1-150; done
echo "== fake"; grep -E "client gui|client bind|stream create|F3000001|TX " $S/ff_station.log | cut -c1-130
for spec in $COPIES; do n=${spec%%:*}; pkill -f "jtdx -r $n\$"; done; sleep 4
for spec in $COPIES; do n=${spec%%:*}; pkill -9 -f "jtdx -r $n\$"; pkill -f "jtdxjt9 -s JTDX-VU - $n"; done; pkill -f "[f]ake_flex.py --port 4993"; sleep 1
for spec in $COPIES; do n=${spec%%:*}; cp "$(DATA $n)/flex_trace.txt" $S/trace_$n.txt 2>/dev/null; rm -f "$(INI $n)"; rm -rf "$(DATA $n)"; done
echo "logs in $S"
