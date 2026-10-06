#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
iverilog -g2012 -Wall -s tb_savestate_controller -o "$BUILD/controller.vvp" \
  "$ROOT/target/pocket/savestate_controller.sv" \
  "$ROOT/tests/savestate_protocol/tb_savestate_controller.sv"
vvp "$BUILD/controller.vvp"
# Guard-discrimination checks: deleting a completion seal or its fresh-session
# requirement must turn the focused test into an explicit failure.
python3 - "$ROOT/target/pocket/savestate_controller.sv" "$BUILD" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text();out=Path(sys.argv[2])
mutations={
    'unsealed-save':('!operation_load && (!save_clear_seen || !save_complete_sys[2])',"1'b0"),
    'stale-save-seal':('(!save_clear_seen || !save_complete_sys[2])','(!save_complete_sys[2])'),
}
for name,(old,new) in mutations.items():
    assert source.count(old)==1,name
    (out/(name+'.sv')).write_text(source.replace(old,new))
PY
for name in unsealed-save stale-save-seal; do
  iverilog -g2012 -s tb_savestate_controller -o "$BUILD/$name.vvp" \
    "$BUILD/$name.sv" "$ROOT/tests/savestate_protocol/tb_savestate_controller.sv"
  if vvp "$BUILD/$name.vvp" >"$BUILD/$name.log" 2>&1; then
    echo "FAIL: mutation $name escaped regression" >&2
    exit 1
  fi
  if [[ "$name" == unsealed-save ]]; then
    grep -q 'Empty fake walk became successful snapshot' "$BUILD/$name.log"
  else
    grep -q 'Stale save seal accepted as current snapshot' "$BUILD/$name.log"
  fi
  echo "PASS: $name mutation rejected"
done
