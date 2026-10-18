// JTDX-VU check: stations on the Ignore list (right-click a decode > Ignore)
// are never picked by QsoHistory::autoseq, the base call is what counts, and
// with every caller ignored nobody is picked.
//
// Build (macOS, Homebrew qt@5):
//   Q=/opt/homebrew/opt/qt@5; M=$(mktemp -d)
//   clang++ -std=c++17 -I. -F$Q/lib -I$Q/lib/QtCore.framework/Headers \
//     -I$Q/lib/QtNetwork.framework/Headers \
//     -framework QtCore -framework QtNetwork -Wl,-rpath,$Q/lib \
//     tools/autoseq_ignore_test.cpp qsohistory.cpp Radio.cpp -o $M/autoseq_ignore_test
// Run: $M/autoseq_ignore_test   (prints each check, exits 1 if any failed)

#include <QCoreApplication>
#include <cstdio>
#include "qsohistory.h"
static int fails = 0;
static void check (bool ok, char const* w) { std::printf ("%s  %s\n", ok ? "ok  " : "FAIL", w); if (!ok) ++fails; }
static QString pick (QStringList const& ignored, QString const& who, QsoHistory::Status st)
{
  QsoHistory h; h.init (); h.owndata ("AS", "VU", "MK83", false);
  h.setIgnored (ignored);
  unsigned t = 3600;
  h.time (t);
  h.message (who, st, 0, "", "", "EU", "UT", t, "-10", 1500, "FT4");
  h.message ("DL1ABC", st, 0, "", "", "EU", "DL", t, "-20", 1700, "FT4");
  QString call, grid, rep, mode; int rx = 0, tx = 0, count = 0, prio = 0; unsigned tm = 128 | 64;  // answer and call worked-before stations, as with no "new" filters
  h.autoseq (call, grid, rep, rx, tx, tm, count, prio, mode);
  return call;
}
int main (int argc, char* argv[])
{
  QCoreApplication a (argc, argv);
  QString p1 = pick ({}, "UT7QF", QsoHistory::RCALL);
  std::printf ("  no ignore -> %s\n", qPrintable (p1));
  check (!p1.isEmpty (), "a caller is picked when nobody is ignored");
  QString p2 = pick ({p1}, p1, QsoHistory::RCALL);
  std::printf ("  ignoring %s -> %s\n", qPrintable (p1), qPrintable (p2));
  check (p2 != p1, "the ignored caller is never picked");
  QString p3 = pick ({"UT7QF", "DL1ABC"}, "UT7QF", QsoHistory::RCALL);
  check (p3.isEmpty (), "nobody picked when every caller is ignored");
  QString p4 = pick ({"UT7QF/P"}, "UT7QF", QsoHistory::RCALL);
  check (p4 != "UT7QF", "ignoring a portable call ignores the base call");
  return fails ? 1 : 0;
}
