#!/usr/bin/env bash
# Self-test for scripts/collect-artifacts.sh.
#
# Builds a synthetic PlatformIO project (ESP32 + ESP8266 envs) with a stub
# esptool, runs the collector, and asserts the bundle layout, merged image and
# flashing commands. Works on Linux and on Windows git-bash (cygwin).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then
  WORK_DIR="$(cygpath -m "${WORK_DIR}")"
fi
trap 'rm -rf "${WORK_DIR}"' EXIT

PROJECT_DIR="${WORK_DIR}/project"
CORE_DIR="${WORK_DIR}/core"
BUNDLE_DIR="${WORK_DIR}/bundle"

mkdir -p "${PROJECT_DIR}/.pio/build/esp32dev" "${PROJECT_DIR}/.pio/build/nodemcuv2"
mkdir -p "${PROJECT_DIR}/src"
mkdir -p "${CORE_DIR}/platforms/espressif32/boards"
mkdir -p "${CORE_DIR}/platforms/espressif8266/boards"
mkdir -p "${CORE_DIR}/packages/tool-esptoolpy"

cat > "${PROJECT_DIR}/platformio.ini" <<'EOF'
[env:esp32dev]
platform = espressif32@6.9.0
board = esp32dev
framework = arduino

[env:nodemcuv2]
platform = espressif8266
board = nodemcuv2
framework = arduino
EOF

for file in bootloader.bin partitions.bin boot_app0.bin firmware.bin firmware.elf; do
  printf 'fake-%s' "${file}" > "${PROJECT_DIR}/.pio/build/esp32dev/${file}"
done
printf 'fake-firmware-8266' > "${PROJECT_DIR}/.pio/build/nodemcuv2/firmware.bin"

cat > "${CORE_DIR}/platforms/espressif32/boards/esp32dev.json" <<'EOF'
{"build": {"mcu": "esp32"}}
EOF
cat > "${CORE_DIR}/platforms/espressif8266/boards/nodemcuv2.json" <<'EOF'
{"build": {"mcu": "esp8266"}}
EOF

# Stub esptool: merge_bin must create the target file so the merge path is covered.
cat > "${CORE_DIR}/packages/tool-esptoolpy/esptool.py" <<'PY'
import sys

argv = sys.argv[1:]
if "merge_bin" in argv and "-o" in argv:
    with open(argv[argv.index("-o") + 1], "wb") as handle:
        handle.write(b"merged-image")
PY

PYTHON_BIN="$(command -v python3 || command -v python || true)"
if [[ -z "${PYTHON_BIN}" ]]; then
  echo "SKIP: no python available, cannot exercise chip detection / merge path" >&2
fi

PLATFORMIO_CORE_DIR="${CORE_DIR}" \
  PYTHON_BIN="${PYTHON_BIN}" \
  bash "${REPO_ROOT}/scripts/collect-artifacts.sh" "${PROJECT_DIR}" "${BUNDLE_DIR}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -f "${BUNDLE_DIR}/esp32dev/firmware.bin" ]] || fail "esp32dev firmware.bin missing"
[[ -f "${BUNDLE_DIR}/esp32dev/firmware.elf" ]] || fail "esp32dev firmware.elf missing"
[[ -f "${BUNDLE_DIR}/nodemcuv2/firmware.bin" ]] || fail "nodemcuv2 firmware.bin missing"
[[ -f "${BUNDLE_DIR}/BUILD-INFO.txt" ]] || fail "BUILD-INFO.txt missing"

if [[ -n "${PYTHON_BIN}" ]]; then
  [[ -f "${BUNDLE_DIR}/esp32dev/merged-0x0.bin" ]] || fail "merged-0x0.bin missing"
  grep -q 'write_flash 0x0 merged-0x0.bin' "${BUNDLE_DIR}/esp32dev/flash_args.txt" \
    || fail "merged flash command missing"
  grep -q '0x1000 bootloader.bin' "${BUNDLE_DIR}/esp32dev/flash_args.txt" \
    || fail "ESP32 bootloader offset missing"
  grep -q '0x10000 firmware.bin' "${BUNDLE_DIR}/esp32dev/flash_args.txt" \
    || fail "ESP32 app offset missing"
fi

grep -q 'write_flash 0x0 firmware.bin' "${BUNDLE_DIR}/nodemcuv2/flash_args.txt" \
  || fail "ESP8266 0x0 flash command missing"

echo "OK: collect-artifacts.sh bundle layout, merge path and flash commands verified"
