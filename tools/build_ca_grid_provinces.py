#!/usr/bin/env python3
"""Build JTDX-VU's grid -> Canadian province table (ca_grid_provinces.txt).

The Canada half of Show US State / Canadian province: for every 4-character
Maidenhead square that touches a province or territory, list the ones it
covers, the largest share of the square's Canadian land first, so a CQ from
FN25 shows as Canada:ON-QC. Codes are Canada Post's (NL, NS, NB, PE, QC, ON,
MB, SK, AB, BC, YT, NT, NU). Without a grid JTDX-VU uses the callsign's
prefix instead (logbook/usstates.cpp), so no callsign table is needed.

Source: Natural Earth 1:10m admin-1 states and provinces (public domain), e.g.
  https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_1_states_provinces.zip
Needs shapely and pyshp:
  python3 -m venv v && v/bin/pip install shapely pyshp
  v/bin/python tools/build_ca_grid_provinces.py ne_10m_admin_1_states_provinces.shp ca_grid_provinces.txt

A province is listed when it holds at least MIN_SHARE of the square's
Canadian land, as in tools/build_us_grid_states.py.
"""
import math
import sys

import shapefile
from shapely.geometry import box, shape
from shapely.ops import unary_union

MIN_SHARE = 0.02
PROVINCES = {"NL", "NS", "NB", "PE", "QC", "ON", "MB", "SK", "AB", "BC", "YT", "NT", "NU"}


def grid_name(lon0, lat0):
    """Square whose south-west corner is (lon0, lat0); lon0 even, both whole degrees."""
    lon = lon0 + 180
    lat = lat0 + 90
    return (chr(ord("A") + lon // 20) + chr(ord("A") + lat // 10)
            + str((lon % 20) // 2) + str(lat % 10))


def main(shp_path, out_path):
    shapes = {}
    for rec in shapefile.Reader(shp_path).iterShapeRecords():
        if rec.record["iso_a2"] != "CA":
            continue
        pv = rec.record["postal"]
        if pv not in PROVINCES:
            continue
        geom = shape(rec.shape.__geo_interface__)
        shapes[pv] = unary_union([shapes[pv], geom]) if pv in shapes else geom
    if len(shapes) != len(PROVINCES):
        sys.exit(f"expected {len(PROVINCES)} provinces and territories, got {sorted(shapes)}")

    table = {}
    for pv, geom in shapes.items():
        for part in getattr(geom, "geoms", [geom]):
            minx, miny, maxx, maxy = part.bounds
            for lon0 in range(int(math.floor(minx / 2) * 2), int(math.ceil(maxx)), 2):
                for lat0 in range(int(math.floor(miny)), int(math.ceil(maxy))):
                    area = part.intersection(box(lon0, lat0, lon0 + 2, lat0 + 1)).area
                    if area > 0:
                        g = grid_name(lon0, lat0)
                        table.setdefault(g, {})
                        table[g][pv] = table[g].get(pv, 0.0) + area

    lines = []
    for g in sorted(table):
        areas = table[g]
        total = sum(areas.values())
        pvs = [p for p, a in sorted(areas.items(), key=lambda kv: -kv[1]) if a / total >= MIN_SHARE]
        lines.append(g + " " + " ".join(pvs))
    with open(out_path, "w") as f:
        f.write("# JTDX-VU grid -> Canadian province(s), largest share first; from Natural Earth admin-1\n")
        f.write("\n".join(lines) + "\n")
    print(f"{len(lines)} squares -> {out_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
