#!/usr/bin/env bash
# Self-test for scripts/collect-artifacts.sh.
#
# Covers:
#   A) esptool v4 layout (esptool.py + merge_bin), versioned platform dirs,
#      boot_app0.bin taken from the Arduino framework package
#   B) esptool v5 layout (esptool executable + merge-bin) with merge_bin rejected
#   C) no esptool available -> build still succeeds, reason is printed, no merged image
#
# Works on Linux and on Windows git-bash (cygwin).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then
  WORK_DIR="$(cygpath -m "${WORK_DIR}")"
fi
trap 'rm -rf "${WORK_DIR}"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

make_project() {
  local dir="$1"
  mkdir -p "${dir}/.pio/build/esp32dev" "${dir}/.pio/build/nodemcuv2" "${dir}/src"
  cat > "${dir}/platformio.ini" <<'EOF'
[env:esp32dev]
platform = espressif32@6.9.0
board = esp32dev
framework = arduino

[env:nodemcuv2]
platform = espressif8266
board = nodemcuv2
framework = arduino
EOF
  for file in firmware.bin firmware.elf bootloader.bin partitions.bin; do
    printf 'fake-%s' "${file}" > "${dir}/.pio/build/esp32dev/${file}"
  done
  printf 'fake-firmware-8266' > "${dir}/.pio/build/nodemcuv2/firmware.bin"
}

make_core() {
  local core="$1"
  # Versioned platform directories, as PlatformIO 6.x may use.
  mkdir -p "${core}/platforms/espressif32@6.9.0/boards"
  mkdir -p "${core}/platforms/espressif8266@4.2.1/boards"
  mkdir -p "${core}/packages/framework-arduinoespressif32/tools/partitions"
  cat > "${core}/platforms/espressif32@6.9.0/boards/esp32dev.json" <<'EOF'
{"build": {"mcu": "esp32"}}
EOF
  cat > "${core}/platforms/espressif8266@4.2.1/boards/nodemcuv2.json" <<'EOF'
{"build": {"mcu": "esp8266"}}
EOF
  printf 'fake-boot-app0' > "${core}/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"
}

run_collector() {
  local project="$1" core="$2" bundle="$3" log="$4"
  PLATFORMIO_CORE_DIR="${core}" \
    PYTHON_BIN="$(command -v python3 || command -v python || true)" \
    bash "${REPO_ROOT}/scripts/collect-artifacts.sh" "${project}" "${bundle}" >"${log}" 2>&1
}

assert_file() { [[ -f "$1" ]] || fail "$2"; }

PROJECT_DIR="${WORK_DIR}/project"
make_project "${PROJECT_DIR}"

# ---------------------------------------------------------------------------
# A) esptool v4: esptool.py + merge_bin
# ---------------------------------------------------------------------------
CORE_A="${WORK_DIR}/core-a"
make_core "${CORE_A}"
mkdir -p "${CORE_A}/packages/tool-esptoolpy"
cat > "${CORE_A}/packages/tool-esptoolpy/esptool.py" <<'PY'
import pathlib
import sys

args = sys.argv[1:]
if "-o" in args:
    pathlib.Path(args[args.index("-o") + 1]).write_bytes(b"merged-image")
PY

BUNDLE_A="${WORK_DIR}/bundle-a"
run_collector "${PROJECT_DIR}" "${CORE_A}" "${BUNDLE_A}" "${WORK_DIR}/a.log"

assert_file "${BUNDLE_A}/esp32dev/merged-0x0.bin" "case A: merged-0x0.bin missing"
assert_file "${BUNDLE_A}/esp32dev/boot_app0.bin" "case A: boot_app0.bin not taken from framework package"
assert_file "${BUNDLE_A}/esp32dev/flash_args.txt" "case A: flash_args.txt missing"
assert_file "${BUNDLE_A}/BUILD-INFO.txt" "case A: BUILD-INFO.txt missing"

grep -q 'write_flash 0x0 merged-0x0.bin' "${BUNDLE_A}/esp32dev/flash_args.txt" \
  || fail "case A: merged flash command missing"
grep -q '0xe000 boot_app0.bin' "${BUNDLE_A}/esp32dev/flash_args.txt" \
  || fail "case A: boot_app0 offset missing from flash_args.txt"
grep -q '0x10000 firmware.bin' "${BUNDLE_A}/esp32dev/flash_args.txt" \
  || fail "case A: app offset missing from flash_args.txt"
grep -q 'write_flash 0x0 firmware.bin' "${BUNDLE_A}/nodemcuv2/flash_args.txt" \
  || fail "case A: ESP8266 0x0 flash command missing"

# ---------------------------------------------------------------------------
# B) esptool v5: `esptool` executable, merge_bin rejected, merge-bin accepted
# ---------------------------------------------------------------------------
CORE_B="${WORK_DIR}/core-b"
make_core "${CORE_B}"
mkdir -p "${CORE_B}/packages/tool-esptoolpy"
cat > "${CORE_B}/packages/tool-esptoolpy/esptool" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "${arg}" == "merge_bin" ]]; then
    echo "esptool v5: use merge-bin" >&2
    exit 2
  fi
done
out=""
previous=""
for arg in "$@"; do
  if [[ "${previous}" == "-o" ]]; then out="${arg}"; fi
  previous="${arg}"
done
echo "merge-bin" > "$(dirname "$0")/last-subcommand.txt"
if [[ -n "${out}" ]]; then printf 'merged-v5' > "${out}"; fi
exit 0
SH
chmod +x "${CORE_B}/packages/tool-esptoolpy/esptool"

BUNDLE_B="${WORK_DIR}/bundle-b"
run_collector "${PROJECT_DIR}" "${CORE_B}" "${BUNDLE_B}" "${WORK_DIR}/b.log"

assert_file "${BUNDLE_B}/esp32dev/merged-0x0.bin" "case B: merged image not produced via merge-bin fallback"
grep -q 'merge-bin' "${CORE_B}/packages/tool-esptoolpy/last-subcommand.txt" \
  || fail "case B: collector did not fall back to merge-bin"
grep -q 'boot_app0.bin' "${BUNDLE_B}/esp32dev/flash_args.txt" \
  || fail "case B: boot_app0 missing from flash_args.txt"

# ---------------------------------------------------------------------------
# C) no esptool anywhere -> explicit warning, no merged image, exit code 0
# ---------------------------------------------------------------------------
CORE_C="${WORK_DIR}/core-c"
mkdir -p "${CORE_C}"
BUNDLE_C="${WORK_DIR}/bundle-c"
run_collector "${PROJECT_DIR}" "${CORE_C}" "${BUNDLE_C}" "${WORK_DIR}/c.log"

[[ ! -f "${BUNDLE_C}/esp32dev/merged-0x0.bin" ]] \
  || fail "case C: merged image should not exist without esptool"
grep -q 'merged image skipped' "${WORK_DIR}/c.log" \
  || fail "case C: collector did not print an explicit skip reason"
assert_file "${BUNDLE_C}/esp32dev/flash_args.txt" "case C: flash_args.txt missing"

echo "OK: collect-artifacts.sh verified (v4 merge_bin, v5 merge-bin fallback, boot_app0, skip reasons)"
#!/usr/bin/env bash
# Self-test for scripts/collect-artifacts.sh.
#
# Covers:
#   A) esptool v4 layout (esptool.py + merge_bin), versioned platform dirs,
#      boot_app0.bin taken from the Arduino framework package
#   B) esptool v5 layout (esptool executable + merge-bin) with merge_bin rejected
#   C) no esptool available -> build still succeeds, reason is printed, no merged image
#
# Works on Linux and on Windows git-bash (cygwin).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then
  WORK_DIR="$(cygpath -m "${WORK_DIR}")"
fi
trap 'rm -rf "${WORK_DIR}"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

make_project() {
  local dir="$1"
  mkdir -p "${dir}/.pio/build/esp32dev" "${dir}/.pio/build/nodemcuv2" "${dir}/src"
  cat > "${dir}/platformio.ini" <<'EOF'
[env:esp32dev]
platform = espressif32@6.9.0
board = esp32dev
framework = arduino

[env:nodemcuv2]
platform = espressif8266
board = nodemcuv2
framework = arduino
EOF
  for file in firmware.bin firmware.elf bootloader.bin partitions.bin; do
    printf 'fake-%s' "${file}" > "${dir}/.pio/build/esp32dev/${file}"
  done
  printf 'fake-firmware-8266' > "${dir}/.pio/build/nodemcuv2/firmware.bin"
}

make_core() {
  local core="$1"
  # Versioned platform directories, as PlatformIO 6.x may use.
  mkdir -p "${core}/platforms/espressif32@6.9.0/boards"
  mkdir -p "${core}/platforms/espressif8266@4.2.1/boards"
  mkdir -p "${core}/packages/framework-arduinoespressif32/tools/partitions"
  cat > "${core}/platforms/espressif32@6.9.0/boards/esp32dev.json" <<'EOF'
{"build": {"mcu": "esp32"}}
EOF
  cat > "${core}/platforms/espressif8266@4.2.1/boards/nodemcuv2.json" <<'EOF'
{"build": {"mcu": "esp8266"}}
EOF
  printf 'fake-boot-app0' > "${core}/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"
}

run_collector() {
  local project="$1" core="$2" bundle="$3" log="$4"
  PLATFORMIO_CORE_DIR="${core}" \
    PYTHON_BIN="$(command -v python3 || command -v python || true)" \
    bash "${REPO_ROOT}/scripts/collect-artifacts.sh" "${project}" "${bundle}" >"${log}" 2>&1
}

assert_file() { [[ -f "$1" ]] || fail "$2"; }

PROJECT_DIR="${WORK_DIR}/project"
make_project "${PROJECT_DIR}"

# ---------------------------------------------------------------------------
# A) esptool v4: esptool.py + merge_bin
# ---------------------------------------------------------------------------
CORE_A="${WORK_DIR}/core-a"
make_core "${CORE_A}"
mkdir -p "${CORE_A}/packages/tool-esptoolpy"
cat > "${CORE_A}/packages/tool-esptoolpy/esptool.py" <<'PY'
import pathlib
import sys

args = sys.argv[1:]
if "-o" in args:
    pathlib.Path(args[args.index("-o") + 1]).write_bytes(b"merged-image")
PY

BUNDLE_A="${WORK_DIR}/bundle-a"
run_collector "${PROJECT_DIR}" "${CORE_A}" "${BUNDLE_A}" "${WORK_DIR}/a.log"

assert_file "${BUNDLE_A}/esp32dev/merged-0x0.bin" "case A: merged-0x0.bin missing"
assert_file "${BUNDLE_A}/esp32dev/boot_app0.bin" "case A: boot_app0.bin not taken from framework package"
assert_file "${BUNDLE_A}/esp32dev/flash_args.txt" "case A: flash_args.txt missing"
assert_file "${BUNDLE_A}/BUILD-INFO.txt" "case A: BUILD-INFO.txt missing"

grep -q 'write_flash 0x0 merged-0x0.bin' "${BUNDLE_A}/esp32dev/flash_args.txt" \
  || fail "case A: merged flash command missing"
grep -q '0xe000 boot_app0.bin' "${BUNDLE_A}/esp32dev/flash_args.txt" \
  || fail "case A: boot_app0 offset missing from flash_args.txt"
grep -q '0x10000 firmware.bin' "${BUNDLE_A}/esp32dev/flash_args.txt" \
  || fail "case A: app offset missing from flash_args.txt"
grep -q 'write_flash 0x0 firmware.bin' "${BUNDLE_A}/nodemcuv2/flash_args.txt" \
  || fail "case A: ESP8266 0x0 flash command missing"

# ---------------------------------------------------------------------------
# B) esptool v5: `esptool` executable, merge_bin rejected, merge-bin accepted
# ---------------------------------------------------------------------------
CORE_B="${WORK_DIR}/core-b"
make_core "${CORE_B}"
mkdir -p "${CORE_B}/packages/tool-esptoolpy"
cat > "${CORE_B}/packages/tool-esptoolpy/esptool" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "${arg}" == "merge_bin" ]]; then
    echo "esptool v5: use merge-bin" >&2
    exit 2
  fi
done
out=""
previous=""
for arg in "$@"; do
  if [[ "${previous}" == "-o" ]]; then out="${arg}"; fi
  previous="${arg}"
done
echo "merge-bin" > "$(dirname "$0")/last-subcommand.txt"
if [[ -n "${out}" ]]; then printf 'merged-v5' > "${out}"; fi
exit 0
SH
chmod +x "${CORE_B}/packages/tool-esptoolpy/esptool"

BUNDLE_B="${WORK_DIR}/bundle-b"
run_collector "${PROJECT_DIR}" "${CORE_B}" "${BUNDLE_B}" "${WORK_DIR}/b.log"

assert_file "${BUNDLE_B}/esp32dev/merged-0x0.bin" "case B: merged image not produced via merge-bin fallback"
grep -q 'merge-bin' "${CORE_B}/packages/tool-esptoolpy/last-subcommand.txt" \
  || fail "case B: collector did not fall back to merge-bin"
grep -q 'boot_app0.bin' "${BUNDLE_B}/esp32dev/flash_args.txt" \
  || fail "case B: boot_app0 missing from flash_args.txt"

# ---------------------------------------------------------------------------
# C) no esptool anywhere -> explicit warning, no merged image, exit code 0
# ---------------------------------------------------------------------------
CORE_C="${WORK_DIR}/core-c"
mkdir -p "${CORE_C}"
BUNDLE_C="${WORK_DIR}/bundle-c"
run_collector "${PROJECT_DIR}" "${CORE_C}" "${BUNDLE_C}" "${WORK_DIR}/c.log"

[[ ! -f "${BUNDLE_C}/esp32dev/merged-0x0.bin" ]] \
  || fail "case C: merged image should not exist without esptool"
grep -q 'merged image skipped' "${WORK_DIR}/c.log" \
  || fail "case C: collector did not print an explicit skip reason"
assert_file "${BUNDLE_C}/esp32dev/flash_args.txt" "case C: flash_args.txt missing"

echo "OK: collect-artifacts.sh verified (v4 merge_bin, v5 merge-bin fallback, boot_app0, skip reasons)"
