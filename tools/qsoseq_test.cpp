// JTDX-VU QSO-state check: QsoHistory::message, the per-station status the
// auto-sequencer reads to pick the next Tx message.
//
// Build (macOS, Homebrew qt@5):
//   Q=/opt/homebrew/opt/qt@5; M=$(mktemp -d)
//   clang++ -std=c++17 -I. -F$Q/lib -I$Q/lib/QtCore.framework/Headers \
//     -I$Q/lib/QtNetwork.framework/Headers \
//     -framework QtCore -framework QtNetwork -Wl,-rpath,$Q/lib \
//     tools/qsoseq_test.cpp qsohistory.cpp Radio.cpp -o $M/qsoseq_test
// Build (Linux):
//   M=$(mktemp -d)
//   g++ -std=c++17 -fPIC -I. tools/qsoseq_test.cpp qsohistory.cpp Radio.cpp \
//     $(pkg-config --cflags --libs Qt5Core Qt5Network) -o $M/qsoseq_test
// Run: $M/qsoseq_test   (prints each check, exits 1 if any failed)

#include <QCoreApplication>
#include <QString>
#include <cstdio>

#include "qsohistory.h"

static int failures = 0;

static void check (bool ok, char const * what)
{
  std::printf ("%s  %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) ++failures;
}

static QsoHistory fresh ()
{
  QsoHistory h;
  h.init ();
  h.owndata ("AS", "VU", "MK83", false);
  return h;
}

// what the decode pane feeds in for a station's message (rx) or our own Tx (tx)
static void rx (QsoHistory& h, QsoHistory::Status s, unsigned t, QString const& param = "")
{
  h.time (t);
  h.message ("OK1JRD", s, 0, param, "", "EU", "OK", t, "", 1500, "FT8");
}

static void tx (QsoHistory& h, QsoHistory::Status s, unsigned t, QString const& param = "", QString const& tyyp = "")
{
  h.message ("OK1JRD", s, 0, param, tyyp, "", "", t, "", 1200, "FT8");
}

static QsoHistory::Status status (QsoHistory& h)
{
  QString grid;
  return h.status ("OK1JRD", grid);
}

int main (int argc, char * argv[])
{
  QCoreApplication app {argc, argv};
  unsigned const t0 = 36000;   // 10:00:00

  // issue #6: OK1JRD calls us, we send -17, it works F4LQJ meanwhile and sends
  // F4LQJ 73 - we are still in QSO with it, so keep sending the report
  {
    QsoHistory h = fresh ();
    rx (h, QsoHistory::RCALL, t0, "JN79");           // VU2CPL OK1JRD JN79
    tx (h, QsoHistory::SREPORT, t0 + 15, "-17");     // OK1JRD VU2CPL -17
    rx (h, QsoHistory::NONE, t0 + 30);               // F4LQJ OK1JRD R+11
    tx (h, QsoHistory::SREPORT, t0 + 45, "-17");
    rx (h, QsoHistory::RFIN, t0 + 60);               // F4LQJ OK1JRD 73
    check (status (h) == QsoHistory::SREPORT, "called us, got our report, 73 to another -> still SREPORT (#6)");
  }

  // Skip Tx1: we answered OK1JRD's CQ straight with a report, it picked someone
  // else and sent them 73 - it never had us, so it's free again
  {
    QsoHistory h = fresh ();
    rx (h, QsoHistory::RCQ, t0, "JN79");             // CQ OK1JRD JN79
    tx (h, QsoHistory::SREPORT, t0 + 15, "-17", "S");
    rx (h, QsoHistory::RFIN, t0 + 30);
    check (status (h) == QsoHistory::RFIN, "answered its CQ with a report, 73 to another -> RFIN (unchanged)");
  }

  // it called us but we haven't replied yet: its call to us stays pending
  {
    QsoHistory h = fresh ();
    rx (h, QsoHistory::RCALL, t0, "JN79");
    rx (h, QsoHistory::RFIN, t0 + 30);
    check (status (h) == QsoHistory::RCALL, "called us, no reply from us yet, 73 to another -> RCALL (unchanged)");
  }

  // called us more than 5 min ago: the stale-QSO rule still resets it
  {
    QsoHistory h = fresh ();
    rx (h, QsoHistory::RCALL, t0, "JN79");
    tx (h, QsoHistory::SREPORT, t0 + 15, "-17");
    rx (h, QsoHistory::RFIN, t0 + 400);
    check (status (h) == QsoHistory::RFIN, "called us 400 s ago, 73 to another -> RFIN (stale, unchanged)");
  }

  // a CQ from it after calling us still means it gave up on us
  {
    QsoHistory h = fresh ();
    rx (h, QsoHistory::RCALL, t0, "JN79");
    tx (h, QsoHistory::SREPORT, t0 + 15, "-17");
    rx (h, QsoHistory::RCQ, t0 + 30, "JN79");
    check (status (h) == QsoHistory::RCQ, "called us, got our report, then CQ -> RCQ (unchanged)");
  }

  std::printf ("%s: %d failed\n", failures ? "FAILED" : "PASSED", failures);
  return failures ? 1 : 0;
}
