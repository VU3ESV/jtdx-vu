// JTDX-VU call-parsing check: Radio::is_callsign and DecodedText::deCallAndGrid,
// the two helpers a double-click on a decode goes through before it picks a DX call.
//
// Build (macOS, Homebrew qt@5) - leave QT_NO_DEBUG undefined so Qt's Q_ASSERTs
// stay on (QString::at past the end aborts instead of reading garbage):
//   Q=/opt/homebrew/opt/qt@5; M=$(mktemp -d)
//   $Q/bin/moc decodedtext.h -o $M/moc_decodedtext.cpp
//   clang++ -std=c++17 -Dfortran_charlen_t=size_t -I. -I$M -F$Q/lib \
//     -I$Q/lib/QtCore.framework/Headers -I$Q/lib/QtNetwork.framework/Headers \
//     -framework QtCore -framework QtNetwork -Wl,-rpath,$Q/lib \
//     tools/callparse_test.cpp Radio.cpp decodedtext.cpp -o $M/callparse_test
// Build (Linux):
//   M=$(mktemp -d)
//   "$(pkg-config --variable=host_bins Qt5Core)/moc" decodedtext.h -o $M/moc_decodedtext.cpp
//   g++ -std=c++17 -fPIC -Dfortran_charlen_t=size_t -I. -I$M \
//     tools/callparse_test.cpp Radio.cpp decodedtext.cpp \
//     $(pkg-config --cflags --libs Qt5Core Qt5Network) -o $M/callparse_test
// Run: $M/callparse_test   (prints each check, exits 1 if any failed)

#include <QCoreApplication>
#include <QString>
#include <cstddef>
#include <cstdio>

#include "Radio.hpp"
#include "decodedtext.h"

// DecodedText's constructor asks the Fortran stdmsg_ whether a message is
// standard; deCallAndGrid doesn't use the answer, so no Fortran is linked
extern "C" bool stdmsg_ (char const *, std::size_t) { return false; }

static int failures = 0;

static void check (bool ok, char const * what)
{
  std::printf ("%s  %s\n", ok ? "ok  " : "FAIL", what);
  if (!ok) ++failures;
}

// an FT decode line as the decode panes show it: the message starts at column 23
static QString ft (char const * message)
{
  return QString {"123445 -12  0.2 1234 ~ "} + message;
}

static QString de_call (QString const& line)
{
  DecodedText decoded {line};
  QString call, grid;
  decoded.deCallAndGrid (call, grid);
  return call;
}

int main (int argc, char * argv[])
{
  QCoreApplication app {argc, argv};

  // is_callsign: an empty or one-letter word used to read at(1) past its end
  check (!Radio::is_callsign (""), "is_callsign(\"\") is false (no read past the end)");
  check (Radio::is_callsign ("F"), "is_callsign(\"F\") still true (one-letter prefix)");
  check (!Radio::is_callsign ("X"), "is_callsign(\"X\") false");
  check (Radio::is_callsign ("K1ABC"), "is_callsign(\"K1ABC\")");
  check (Radio::is_callsign ("VU3ESV"), "is_callsign(\"VU3ESV\")");
  check (!Radio::is_callsign ("TNX"), "is_callsign(\"TNX\") false");

  // deCallAndGrid: the second word is the sender
  check (de_call (ft ("CQ K1ABC FN42")) == "K1ABC", "CQ K1ABC FN42 -> K1ABC");
  check (de_call (ft ("VU3ESV K1ABC -12")) == "K1ABC", "VU3ESV K1ABC -12 -> K1ABC");
  check (de_call (ft ("VU3ESV K1ABC RR73")) == "K1ABC", "VU3ESV K1ABC RR73 -> K1ABC");
  check (de_call (ft ("ES1JA SX60RAAG RR73")) == "SX60RAAG", "DXpedition split ES1JA SX60RAAG RR73 -> SX60RAAG");
  check (de_call (ft ("VU3ESV 73")).isEmpty (), "VU3ESV 73 -> no call");
  check (de_call (ft ("TNX 73 GL")).isEmpty (), "TNX 73 GL -> no call");
  // RR73 fits the call pattern; it used to become the DX call
  check (de_call (ft ("TU RR73")).isEmpty (), "TU RR73 -> no call (was RR73)");
  check (de_call (ft ("VU3ESV RR73")).isEmpty (), "VU3ESV RR73 -> no call (was RR73)");
  // a Fox's compound message when the decoder leaves it unsplit (msgparser
  // splits most into two ordinary lines): word2 stops at the ';'
  check (de_call (ft ("VU3ESV RR73; W2XYZ <PJ4X> -08")).isEmpty (), "Fox VU3ESV RR73; W2XYZ <PJ4X> -08 -> no call (was RR73)");

  std::printf ("%s: %d failed\n", failures ? "FAILED" : "PASSED", failures);
  return failures ? 1 : 0;
}
