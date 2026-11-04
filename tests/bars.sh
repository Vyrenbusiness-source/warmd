#!/usr/bin/env bash
# Chart check: inside each card, bar width must be proportional to its value (2% tolerance), and a smaller value is never wider.
set -u
cd "$(dirname "$0")/.." || exit 1
bad=0
for f in docs/assets/speed.html docs/assets/tokens.html; do
  out=$(awk -v f="$f" '
    /class="card/ { n++; delete v; delete w; k=0 }
    match($0, /data-v="[^"]+"/) {
      val=substr($0, RSTART+8, RLENGTH-9)
      match($0, /style="width:[0-9.]+%/); wd=substr($0, RSTART+13, RLENGTH-14)
      nb++; k++; v[k]=val+0; w[k]=wd+0; card[n]=k
      for (i=1; i<k; i++) {
        if (v[i] > 0 && w[i] > 0) {
          r=(w[k]/v[k])/(w[i]/v[i]); if (r<0.98 || r>1.02) { print f ": card " n ": width ratio off (" v[i] " vs " v[k] ")"; bad=1 }
        }
        if ((v[k]<v[i] && w[k]>w[i]) || (v[k]>v[i] && w[k]<w[i])) { print f ": card " n ": smaller value is wider (" v[i] " vs " v[k] ")"; bad=1 }
      }
    }
    END { if (!n || !nb) { print f ": no cards found"; bad=1 } exit bad }' "$f") || { echo "$out"; bad=1; }
done
[ "$bad" = 0 ] && echo "ok   chart bars are proportional" || { echo "FAIL chart bars"; exit 1; }
