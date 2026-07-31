#!/bin/bash
# Build the single-file web client.
#
# The sim core compiles to WebAssembly with clang alone: it has no libc
# dependency beyond memcpy and memset, which wasm_shim.c supplies. No
# emscripten, no runtime, no glue. The .wasm is then embedded in the page as
# base64 so the result is one file that runs from anywhere, including file://.
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build

clang --target=wasm32 -O2 -std=c99 -nostdlib \
  -I../sim/include -Ifreestanding \
  -Wl,--no-entry -Wl,--export-dynamic -Wl,--allow-undefined \
  -Wl,-z,stack-size=131072 -Wl,--initial-memory=33554432 \
  wasm_shim.c ../sim/src/sim.c ../sim/src/baseline.c \
  -o build/vectorwake.wasm

python3 - <<'PY'
import base64, pathlib
wasm = pathlib.Path("build/vectorwake.wasm").read_bytes()
page = pathlib.Path("index.html").read_text()
out = page.replace("__WASM_BASE64__", base64.b64encode(wasm).decode())
pathlib.Path("build/vectorwake.html").write_text(out)
print(f"build/vectorwake.html  ({len(out)/1024:.0f} KB, wasm {len(wasm)/1024:.0f} KB)")
PY
