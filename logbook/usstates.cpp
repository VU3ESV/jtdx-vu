// JTDX-VU: Show US State, see usstates.h
#include "usstates.h"

#include <QDir>
#include <QRegularExpression>
#include <QFile>
#include <QStandardPaths>
#include "Radio.hpp"

namespace
{
  QByteArray read_table (QString const& name)
  {
    QDir const data {QStandardPaths::writableLocation (QStandardPaths::DataLocation)};
    QFile file {data.exists (name) ? data.absoluteFilePath (name) : ":/" + name};
    return file.open (QIODevice::ReadOnly) ? file.readAll () : QByteArray {};
  }

  void read_grids (QString const& name, QHash<QString, QString>& into)
  {
    for (auto const& line : read_table (name).split ('\n'))
      {
        if (line.isEmpty () || line.startsWith ('#')) continue;
        auto const f = QString::fromLatin1 (line).split (' ', QString::SkipEmptyParts);
        if (f.size () >= 2) into.insert (f[0], QStringList (f.mid (1)).join ('-'));
      }
  }

  QString grid_of (QString const& grid)
  {
    QString const g = grid.trimmed ().left (4).toUpper ();
    return g.size () == 4 && g != "RR73" ? g : QString {};
  }

  QString base_of (QString const& call)
  {
    QString base = Radio::base_callsign (call.trimmed ().toUpper ());
    if (base.startsWith ('<')) base = base.mid (1, base.size () - 2);
    return base;
  }

  // Canadian call areas: the digit after the prefix gives the province.
  // VE/VA 1-9; VO1/VO2 Newfoundland and Labrador; VY0 Nunavut, VY1 Yukon,
  // VY2 PEI; special-event prefixes (CF-CK, CZ, VB-VD, VG, VX, XJ-XO) use
  // the VE digits. VE0 (maritime mobile), VY9 and the rest give nothing.
  QString canada_by_prefix (QString const& base)
  {
    static QRegularExpression const re {"^([A-Z]{2})([0-9])"};
    auto const m = re.match (base);
    if (!m.hasMatch ()) return {};
    QString const p = m.captured (1);
    int const d = m.captured (2).toInt ();
    static char const * const ve[] {"", "NS", "QC", "ON", "MB", "SK", "AB", "BC", "NT", "NB"};
    if (p == "VE" || p == "VA") return QString {ve[d]};
    if (p == "VO") return d == 1 || d == 2 ? QString {"NL"} : QString {};
    if (p == "VY") return d == 0 ? QString {"NU"} : d == 1 ? QString {"YT"} : d == 2 ? QString {"PE"} : QString {};
    static QStringList const special {"CF", "CG", "CH", "CI", "CJ", "CK", "CZ", "VB", "VC", "VD", "VG", "VX",
                                      "XJ", "XK", "XL", "XM", "XN", "XO"};
    if (special.contains (p) && d >= 1 && d != 8) return QString {ve[d]};
    return {};
  }
}

void UsStates::load ()
{
  loaded_ = true;
  read_grids ("us_grid_states.txt", grids_);
  read_grids ("ca_grid_provinces.txt", caGrids_);
  calls_ = read_table ("us_call_states.txt");
  offsets_.reserve (calls_.size () / 9);
  for (int i = 0; i < calls_.size (); )
    {
      offsets_ << i;
      int const nl = calls_.indexOf ('\n', i);
      if (nl < 0) break;
      i = nl + 1;
    }
}

QString UsStates::byCall (QString const& call) const
{
  QByteArray const key = call.toLatin1 ();
  int lo = 0, hi = offsets_.size () - 1;
  while (lo <= hi)
    {
      int const mid = (lo + hi) / 2;
      int const start = offsets_[mid];
      int const space = calls_.indexOf (' ', start);
      if (space < 0) return {};
      int const cmp = qstrcmp (calls_.mid (start, space - start), key);
      if (cmp == 0) return QString::fromLatin1 (calls_.mid (space + 1, 2));
      if (cmp < 0) lo = mid + 1; else hi = mid - 1;
    }
  return {};
}

QString UsStates::find (QString const& call, QString const& grid)
{
  if (!loaded_) load ();
  QString const g = grid_of (grid);
  if (!g.isEmpty ())
    {
      auto const it = grids_.constFind (g);
      if (it != grids_.constEnd ()) return it.value ();
    }
  return byCall (base_of (call));
}

QString UsStates::findCanada (QString const& call, QString const& grid)
{
  if (!loaded_) load ();
  QString const g = grid_of (grid);
  if (!g.isEmpty ())
    {
      auto const it = caGrids_.constFind (g);
      if (it != caGrids_.constEnd ()) return it.value ();
    }
  return canada_by_prefix (base_of (call));
}
