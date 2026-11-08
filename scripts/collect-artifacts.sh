#!/usr/bin/env bash
# Collect PlatformIO build outputs into a flat bundle directory.
#
# Usage: bash scripts/collect-artifacts.sh <project-dir> <bundle-dir>
#
# Produces:
#   <bundle-dir>/<env>/firmware.bin|firmware.hex|firmware.uf2|firmware.elf
#   <bundle-dir>/<env>/bootloader.bin|partitions.bin|boot_app0.bin
#   <bundle-dir>/<env>/merged-0x0.bin   (single flashable image, when possible)
#   <bundle-dir>/<env>/flash_args.txt   (ready to paste esptool commands)
#   <bundle-dir>/BUILD-INFO.txt
#
# Environment variables:
#   PLATFORMIO_CORE_DIR  PlatformIO home (default: ~/.platformio)
#   ESPTOOL_PY           explicit path to esptool.py / esptool (auto-discovered otherwise)
#   PYTHON_BIN           python interpreter to use (default: python3, then python)
#
# esptool compatibility: both the v4 single script (`esptool.py` + `merge_bin`)
# and the v5 console script / package (`esptool` + `merge-bin`) are supported.
set -euo pipefail

PROJECT_DIR="${1:?usage: collect-artifacts.sh <project-dir> <bundle-dir>}"
BUNDLE_DIR="${2:?usage: collect-artifacts.sh <project-dir> <bundle-dir>}"

BUILD_ROOT="${PROJECT_DIR}/.pio/build"
PIO_CORE="${PLATFORMIO_CORE_DIR:-${HOME}/.platformio}"

note() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }

if [[ ! -d "${BUILD_ROOT}" ]]; then
  printf 'PlatformIO build directory not found: %s\n' "${BUILD_ROOT}" >&2
  exit 1
fi

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "${PYTHON_BIN}" ]]; then
  for candidate in python3 python; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      PYTHON_BIN="${candidate}"
      break
    fi
  done
fi

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

# Read a key from platformio.ini, preferring [env:<name>] over the shared [env] section.
get_env_value() {
  local ini="$1" key="$2" env_name="$3"
  [[ -f "${ini}" ]] || return 0
  awk -v wantkey="${key}" -v wantenv="${env_name}" '
    function trim(s) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      return s
    }
    {
      line = $0
      sub(/\r$/, "", line)
      stripped = trim(line)
      if (stripped == "" || stripped ~ /^[;#]/) next
      if (stripped ~ /^\[/) {
        section = stripped
        sub(/^\[/, "", section)
        sub(/\].*$/, "", section)
        section = trim(section)
        inenv = (section == ("env:" wantenv))
        inglob = (section == "env")
        next
      }
      eq = index(stripped, "=")
      if (eq == 0) next
      k = trim(substr(stripped, 1, eq - 1))
      v = trim(substr(stripped, eq + 1))
      if (k != wantkey) next
      if (inenv) { specific = v; foundspec = 1; next }
      if (inglob && !foundglob) { glob = v; foundglob = 1 }
    }
    END {
      if (foundspec) print specific
      else if (foundglob) print glob
    }
  ' "${ini}"
}

# ---------------------------------------------------------------------------
# esptool resolution: v4 (esptool.py / merge_bin), v5 (esptool / merge-bin),
# or the python module form (python -m esptool).
# ---------------------------------------------------------------------------
ESPTOOL_KIND=""
ESPTOOL_VALUE=""

resolve_esptool() {
  local candidate name

  if [[ -n "${ESPTOOL_PY:-}" && -f "${ESPTOOL_PY}" ]]; then
    candidate="${ESPTOOL_PY}"
    if [[ "${candidate}" == *.py ]]; then
      ESPTOOL_KIND=script
    else
      ESPTOOL_KIND=exe
    fi
    ESPTOOL_VALUE="${candidate}"
    return 0
  fi

  candidate="$(find "${PIO_CORE}/packages" -maxdepth 4 -type f -name 'esptool.py' -print -quit 2>/dev/null || true)"
  if [[ -n "${candidate}" ]]; then
    ESPTOOL_KIND=script
    ESPTOOL_VALUE="${candidate}"
    return 0
  fi

  candidate="$(find "${PIO_CORE}/packages" -maxdepth 4 -type f -name 'esptool' -print -quit 2>/dev/null || true)"
  if [[ -n "${candidate}" ]]; then
    ESPTOOL_KIND=exe
    ESPTOOL_VALUE="${candidate}"
    return 0
  fi

  candidate="$(find "${PIO_CORE}/packages" -maxdepth 5 -type f -path '*/esptool/__init__.py' -print -quit 2>/dev/null || true)"
  if [[ -n "${candidate}" ]]; then
    ESPTOOL_KIND=module
    ESPTOOL_VALUE="$(dirname "$(dirname "${candidate}")")"
    return 0
  fi

  for name in esptool.py esptool; do
    candidate="$(command -v "${name}" 2>/dev/null || true)"
    if [[ -n "${candidate}" ]]; then
      if [[ "${name}" == *.py ]]; then
        ESPTOOL_KIND=script
      else
        ESPTOOL_KIND=exe
      fi
      ESPTOOL_VALUE="${candidate}"
      return 0
    fi
  done

  return 0
}

run_esptool() {
  case "${ESPTOOL_KIND}" in
    script) "${PYTHON_BIN}" "${ESPTOOL_VALUE}" "$@" ;;
    exe) "${ESPTOOL_VALUE}" "$@" ;;
    module)
      local python_path="${ESPTOOL_VALUE}"
      if [[ -n "${PYTHONPATH:-}" ]]; then
        python_path="${python_path}:${PYTHONPATH}"
      fi
      PYTHONPATH="${python_path}" "${PYTHON_BIN}" -m esptool "$@" ;;
    *) return 127 ;;
  esac
}

# Board JSONs live under <core>/platforms/<platform>[@version]/boards/<board>.json,
# so search instead of assuming an unversioned platform directory.
detect_chip() {
  local board="$1" platform_name="$2" board_json
  [[ -n "${board}" && -n "${PYTHON_BIN}" ]] || return 0
  board_json="$(find "${PIO_CORE}/platforms" -maxdepth 3 -type f \
    -path "*/${platform_name}*/boards/${board}.json" -print -quit 2>/dev/null || true)"
  if [[ -z "${board_json}" ]]; then
    board_json="$(find "${PIO_CORE}/platforms" -maxdepth 3 -type f \
      -path "*/boards/${board}.json" -print -quit 2>/dev/null || true)"
  fi
  [[ -n "${board_json}" ]] || return 0
  "${PYTHON_BIN}" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("build", {}).get("mcu", ""))' "${board_json}" 2>/dev/null || true
}

# boot_app0.bin ships with the Arduino core and initialises the otadata
# partition (0xe000) so the bootloader selects the freshly flashed app0.
find_boot_app0() {
  find "${PIO_CORE}/packages" -maxdepth 6 -type f \
    -path '*/tools/partitions/boot_app0.bin' -print -quit 2>/dev/null || true
}

bootloader_offset() {
  case "$1" in
    esp32 | esp32s2) printf '0x1000' ;;
    esp32s3 | esp32c3 | esp32c2 | esp32c6 | esp32h2 | esp32p4) printf '0x0' ;;
    *) printf '' ;;
  esac
}

copy_if_exists() {
  [[ -f "$1" ]] || return 0
  cp "$1" "$2"
  note "  + $(basename "$2")"
}

# Build merged-0x0.bin and report exactly why it was skipped when it cannot be built.
create_merged_image() {
  local env_dir="$1" env_name="$2" chip="$3" board="$4"
  local merged="merged-0x0.bin" boot_off

  if [[ ! -f "${env_dir}/bootloader.bin" || ! -f "${env_dir}/partitions.bin" || ! -f "${env_dir}/firmware.bin" ]]; then
    warn "merged image skipped for ${env_name}: needs bootloader.bin + partitions.bin + firmware.bin"
    return 0
  fi

  if [[ -z "${chip}" ]]; then
    warn "merged image skipped for ${env_name}: cannot determine chip for board '${board:-unknown}'"
    return 0
  fi

  boot_off="$(bootloader_offset "${chip}")"
  if [[ -z "${boot_off}" ]]; then
    warn "merged image skipped for ${env_name}: merged image is not supported for chip '${chip}'"
    return 0
  fi

  if [[ -z "${ESPTOOL_KIND}" ]]; then
    warn "merged image skipped for ${env_name}: esptool not found under ${PIO_CORE}/packages (set ESPTOOL_PY to override)"
    return 0
  fi

  local segments=("${boot_off}" bootloader.bin 0x8000 partitions.bin)
  if [[ -f "${env_dir}/boot_app0.bin" ]]; then
    segments+=(0xe000 boot_app0.bin)
  fi
  segments+=(0x10000 firmware.bin)

  local subcommand error_log="${env_dir}/.esptool-merge.log" reason=""
  for subcommand in merge_bin merge-bin; do
    rm -f "${env_dir}/${merged}"
    if (
      cd "${env_dir}"
      run_esptool --chip "${chip}" "${subcommand}" -o "${merged}" "${segments[@]}"
    ) >"${error_log}" 2>&1; then
      rm -f "${error_log}"
      note "  + ${merged} (chip: ${chip}, subcommand: ${subcommand})"
      return 0
    fi
  done

  reason="$(tail -n 2 "${error_log}" 2>/dev/null | tr '\n' ' ' || true)"
  rm -f "${error_log}" "${env_dir}/${merged}"
  warn "merged image skipped for ${env_name}: esptool could not merge images (${reason:-unknown error})"
  return 0
}

rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}"

resolve_esptool
if [[ -z "${ESPTOOL_KIND}" ]]; then
  warn "esptool not found: merged images will be skipped, per-image bins are still bundled"
fi

collected_envs=0

for env_path in "${BUILD_ROOT}"/*; do
  [[ -d "${env_path}" ]] || continue
  env_name="$(basename "${env_path}")"

  firmware_candidate=""
  for candidate in firmware.bin firmware.hex firmware.uf2; do
    if [[ -f "${env_path}/${candidate}" ]]; then
      firmware_candidate="${candidate}"
      break
    fi
  done
  [[ -n "${firmware_candidate}" ]] || continue

  env_out="${BUNDLE_DIR}/${env_name}"
  mkdir -p "${env_out}"
  note "Collecting ${env_name} (${firmware_candidate})"

  for file in firmware.bin firmware.hex firmware.uf2 firmware.elf \
    bootloader.bin partitions.bin boot_app0.bin; do
    copy_if_exists "${env_path}/${file}" "${env_out}/${file}"
  done

  board="$(get_env_value "${PROJECT_DIR}/platformio.ini" 'board' "${env_name}")"
  platform_raw="$(get_env_value "${PROJECT_DIR}/platformio.ini" 'platform' "${env_name}")"
  platform_name="${platform_raw%%@*}"
  platform_name="${platform_name//[[:space:]]/}"
  if [[ -z "${platform_name}" ]]; then
    platform_name="espressif32"
  fi
  chip="$(detect_chip "${board}" "${platform_name}")"
  chip="${chip//[[:space:]]/}"

  # Arduino ESP32 builds do not always drop boot_app0.bin into the build dir;
  # take it from the framework package so the bundle can initialise otadata.
  if [[ ! -f "${env_out}/boot_app0.bin" && "${platform_name}" == espressif32* ]]; then
    boot_app0_src="$(find_boot_app0)"
    if [[ -n "${boot_app0_src}" ]]; then
      copy_if_exists "${boot_app0_src}" "${env_out}/boot_app0.bin"
    else
      warn "boot_app0.bin not found under ${PIO_CORE}/packages (framework-arduinoespressif32/tools/partitions)"
    fi
  fi

  create_merged_image "${env_out}" "${env_name}" "${chip}" "${board}"

  flash_lines=()
  flash_lines+=("# env: ${env_name}    board: ${board:-unknown}    chip: ${chip:-unknown}")
  flash_lines+=("# 烧录端口请替换 -p 后面的参数（Windows 例如 COM5，Linux/macOS 例如 /dev/ttyUSB0）")

  if [[ -f "${env_out}/merged-0x0.bin" ]]; then
    flash_lines+=("")
    flash_lines+=("# 方式一（推荐）：单文件镜像，从 0x0 开始写入（含 bootloader/分区表/boot_app0/应用）")
    flash_lines+=("esptool.py --chip ${chip} -p COM_PORT -b 460800 write_flash 0x0 merged-0x0.bin")
    flash_lines+=("")
    flash_lines+=("# 方式二：分段镜像，与 ESP-IDF/PlatformIO 默认布局一致")
  fi

  if [[ -f "${env_out}/bootloader.bin" && -f "${env_out}/partitions.bin" && -f "${env_out}/firmware.bin" ]]; then
    individual="esptool.py --chip ${chip:-esp32} -p COM_PORT -b 460800 write_flash $(bootloader_offset "${chip}") bootloader.bin 0x8000 partitions.bin"
    if [[ -f "${env_out}/boot_app0.bin" ]]; then
      individual="${individual} 0xe000 boot_app0.bin"
    fi
    individual="${individual} 0x10000 firmware.bin"
    flash_lines+=("${individual}")
    flash_lines+=("# 注意：0xe000 的 boot_app0.bin 会初始化 otadata，让 bootloader 启动本次写入的 app0；")
    flash_lines+=("#       若设备之前跑过其他 OTA 固件而少了这一步，可能仍启动旧的 app1。")
  elif [[ -f "${env_out}/firmware.bin" ]]; then
    flash_lines+=("")
    flash_lines+=("# 该环境（${platform_name}）直接把 firmware.bin 写到 0x0")
    flash_lines+=("esptool.py --chip ${chip:-esp8266} -p COM_PORT -b 460800 write_flash 0x0 firmware.bin")
  elif [[ -f "${env_out}/firmware.hex" ]]; then
    flash_lines+=("")
    flash_lines+=("# AVR 等平台请使用 avrdude 烧录 firmware.hex")
    flash_lines+=("avrdude -p <mcu> -c <programmer> -P <port> -U flash:w:firmware.hex:i")
  elif [[ -f "${env_out}/firmware.uf2" ]]; then
    flash_lines+=("")
    flash_lines+=("# 将开发板置于 BOOTSEL/UF2 模式后，直接把 firmware.uf2 复制到对应磁盘")
  fi

  flash_lines+=("")
  flash_lines+=("# 设备此前运行过 OTA 固件、不确定启动哪个分区时，先擦除 otadata：")
  flash_lines+=("#   esptool.py --chip ${chip:-esp32} -p COM_PORT erase_region 0xe000 0x2000")
  flash_lines+=("# 需要擦除整片 flash：esptool.py --chip ${chip:-esp32} -p COM_PORT erase_flash")
  printf '%s\n' "${flash_lines[@]}" > "${env_out}/flash_args.txt"

  collected_envs=$((collected_envs + 1))
done

if [[ "${collected_envs}" -eq 0 ]]; then
  printf 'No firmware images found under %s\n' "${BUILD_ROOT}" >&2
  exit 1
fi

{
  echo "Arduino / PlatformIO build bundle"
  echo "generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "environments: ${collected_envs}"
  echo
  echo "Contents:"
  for env_dir in "${BUNDLE_DIR}"/*/; do
    [[ -d "${env_dir}" ]] || continue
    echo "- $(basename "${env_dir}")"
    for file in "${env_dir}"*; do
      [[ -f "${file}" ]] || continue
      printf '    %-20s %8s bytes\n' "$(basename "${file}")" "$(wc -c < "${file}")"
    done
  done
  echo
  echo "See <env>/flash_args.txt for ready-to-use flashing commands."
  echo "The zip is password protected; use the password shown on the compile web page."
} > "${BUNDLE_DIR}/BUILD-INFO.txt"

echo
echo "Bundle ready: ${BUNDLE_DIR} (${collected_envs} environment(s))"
#!/usr/bin/env bash
# Collect PlatformIO build outputs into a flat bundle directory.
#
# Usage: bash scripts/collect-artifacts.sh <project-dir> <bundle-dir>
#
# Produces:
#   <bundle-dir>/<env>/firmware.bin|firmware.hex|firmware.uf2|firmware.elf
#   <bundle-dir>/<env>/bootloader.bin|partitions.bin|boot_app0.bin
#   <bundle-dir>/<env>/merged-0x0.bin   (single flashable image, when possible)
#   <bundle-dir>/<env>/flash_args.txt   (ready to paste esptool commands)
#   <bundle-dir>/BUILD-INFO.txt
#
# Environment variables:
#   PLATFORMIO_CORE_DIR  PlatformIO home (default: ~/.platformio)
#   ESPTOOL_PY           explicit path to esptool.py / esptool (auto-discovered otherwise)
#   PYTHON_BIN           python interpreter to use (default: python3, then python)
#
# esptool compatibility: both the v4 single script (`esptool.py` + `merge_bin`)
# and the v5 console script / package (`esptool` + `merge-bin`) are supported.
set -euo pipefail

PROJECT_DIR="${1:?usage: collect-artifacts.sh <project-dir> <bundle-dir>}"
BUNDLE_DIR="${2:?usage: collect-artifacts.sh <project-dir> <bundle-dir>}"

BUILD_ROOT="${PROJECT_DIR}/.pio/build"
PIO_CORE="${PLATFORMIO_CORE_DIR:-${HOME}/.platformio}"

note() { printf '%s\n' "$*"; }
warn() { printf 'Warning: %s\n' "$*" >&2; }

if [[ ! -d "${BUILD_ROOT}" ]]; then
  printf 'PlatformIO build directory not found: %s\n' "${BUILD_ROOT}" >&2
  exit 1
fi

PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "${PYTHON_BIN}" ]]; then
  for candidate in python3 python; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      PYTHON_BIN="${candidate}"
      break
    fi
  done
fi

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

# Read a key from platformio.ini, preferring [env:<name>] over the shared [env] section.
get_env_value() {
  local ini="$1" key="$2" env_name="$3"
  [[ -f "${ini}" ]] || return 0
  awk -v wantkey="${key}" -v wantenv="${env_name}" '
    function trim(s) {
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      return s
    }
    {
      line = $0
      sub(/\r$/, "", line)
      stripped = trim(line)
      if (stripped == "" || stripped ~ /^[;#]/) next
      if (stripped ~ /^\[/) {
        section = stripped
        sub(/^\[/, "", section)
        sub(/\].*$/, "", section)
        section = trim(section)
        inenv = (section == ("env:" wantenv))
        inglob = (section == "env")
        next
      }
      eq = index(stripped, "=")
      if (eq == 0) next
      k = trim(substr(stripped, 1, eq - 1))
      v = trim(substr(stripped, eq + 1))
      if (k != wantkey) next
      if (inenv) { specific = v; foundspec = 1; next }
      if (inglob && !foundglob) { glob = v; foundglob = 1 }
    }
    END {
      if (foundspec) print specific
      else if (foundglob) print glob
    }
  ' "${ini}"
}

# ---------------------------------------------------------------------------
# esptool resolution: v4 (esptool.py / merge_bin), v5 (esptool / merge-bin),
# or the python module form (python -m esptool).
# ---------------------------------------------------------------------------
ESPTOOL_KIND=""
ESPTOOL_VALUE=""

resolve_esptool() {
  local candidate name

  if [[ -n "${ESPTOOL_PY:-}" && -f "${ESPTOOL_PY}" ]]; then
    candidate="${ESPTOOL_PY}"
    if [[ "${candidate}" == *.py ]]; then
      ESPTOOL_KIND=script
    else
      ESPTOOL_KIND=exe
    fi
    ESPTOOL_VALUE="${candidate}"
    return 0
  fi

  candidate="$(find "${PIO_CORE}/packages" -maxdepth 4 -type f -name 'esptool.py' -print -quit 2>/dev/null || true)"
  if [[ -n "${candidate}" ]]; then
    ESPTOOL_KIND=script
    ESPTOOL_VALUE="${candidate}"
    return 0
  fi

  candidate="$(find "${PIO_CORE}/packages" -maxdepth 4 -type f -name 'esptool' -print -quit 2>/dev/null || true)"
  if [[ -n "${candidate}" ]]; then
    ESPTOOL_KIND=exe
    ESPTOOL_VALUE="${candidate}"
    return 0
  fi

  candidate="$(find "${PIO_CORE}/packages" -maxdepth 5 -type f -path '*/esptool/__init__.py' -print -quit 2>/dev/null || true)"
  if [[ -n "${candidate}" ]]; then
    ESPTOOL_KIND=module
    ESPTOOL_VALUE="$(dirname "$(dirname "${candidate}")")"
    return 0
  fi

  for name in esptool.py esptool; do
    candidate="$(command -v "${name}" 2>/dev/null || true)"
    if [[ -n "${candidate}" ]]; then
      if [[ "${name}" == *.py ]]; then
        ESPTOOL_KIND=script
      else
        ESPTOOL_KIND=exe
      fi
      ESPTOOL_VALUE="${candidate}"
      return 0
    fi
  done

  return 0
}

run_esptool() {
  case "${ESPTOOL_KIND}" in
    script) "${PYTHON_BIN}" "${ESPTOOL_VALUE}" "$@" ;;
    exe) "${ESPTOOL_VALUE}" "$@" ;;
    module)
      local python_path="${ESPTOOL_VALUE}"
      if [[ -n "${PYTHONPATH:-}" ]]; then
        python_path="${python_path}:${PYTHONPATH}"
      fi
      PYTHONPATH="${python_path}" "${PYTHON_BIN}" -m esptool "$@" ;;
    *) return 127 ;;
  esac
}

# Board JSONs live under <core>/platforms/<platform>[@version]/boards/<board>.json,
# so search instead of assuming an unversioned platform directory.
detect_chip() {
  local board="$1" platform_name="$2" board_json
  [[ -n "${board}" && -n "${PYTHON_BIN}" ]] || return 0
  board_json="$(find "${PIO_CORE}/platforms" -maxdepth 3 -type f \
    -path "*/${platform_name}*/boards/${board}.json" -print -quit 2>/dev/null || true)"
  if [[ -z "${board_json}" ]]; then
    board_json="$(find "${PIO_CORE}/platforms" -maxdepth 3 -type f \
      -path "*/boards/${board}.json" -print -quit 2>/dev/null || true)"
  fi
  [[ -n "${board_json}" ]] || return 0
  "${PYTHON_BIN}" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("build", {}).get("mcu", ""))' "${board_json}" 2>/dev/null || true
}

# boot_app0.bin ships with the Arduino core and initialises the otadata
# partition (0xe000) so the bootloader selects the freshly flashed app0.
find_boot_app0() {
  find "${PIO_CORE}/packages" -maxdepth 6 -type f \
    -path '*/tools/partitions/boot_app0.bin' -print -quit 2>/dev/null || true
}

bootloader_offset() {
  case "$1" in
    esp32 | esp32s2) printf '0x1000' ;;
    esp32s3 | esp32c3 | esp32c2 | esp32c6 | esp32h2 | esp32p4) printf '0x0' ;;
    *) printf '' ;;
  esac
}

copy_if_exists() {
  [[ -f "$1" ]] || return 0
  cp "$1" "$2"
  note "  + $(basename "$2")"
}

# Build merged-0x0.bin and report exactly why it was skipped when it cannot be built.
create_merged_image() {
  local env_dir="$1" env_name="$2" chip="$3" board="$4"
  local merged="merged-0x0.bin" boot_off

  if [[ ! -f "${env_dir}/bootloader.bin" || ! -f "${env_dir}/partitions.bin" || ! -f "${env_dir}/firmware.bin" ]]; then
    warn "merged image skipped for ${env_name}: needs bootloader.bin + partitions.bin + firmware.bin"
    return 0
  fi

  if [[ -z "${chip}" ]]; then
    warn "merged image skipped for ${env_name}: cannot determine chip for board '${board:-unknown}'"
    return 0
  fi

  boot_off="$(bootloader_offset "${chip}")"
  if [[ -z "${boot_off}" ]]; then
    warn "merged image skipped for ${env_name}: merged image is not supported for chip '${chip}'"
    return 0
  fi

  if [[ -z "${ESPTOOL_KIND}" ]]; then
    warn "merged image skipped for ${env_name}: esptool not found under ${PIO_CORE}/packages (set ESPTOOL_PY to override)"
    return 0
  fi

  local segments=("${boot_off}" bootloader.bin 0x8000 partitions.bin)
  if [[ -f "${env_dir}/boot_app0.bin" ]]; then
    segments+=(0xe000 boot_app0.bin)
  fi
  segments+=(0x10000 firmware.bin)

  local subcommand error_log="${env_dir}/.esptool-merge.log" reason=""
  for subcommand in merge_bin merge-bin; do
    rm -f "${env_dir}/${merged}"
    if (
      cd "${env_dir}"
      run_esptool --chip "${chip}" "${subcommand}" -o "${merged}" "${segments[@]}"
    ) >"${error_log}" 2>&1; then
      rm -f "${error_log}"
      note "  + ${merged} (chip: ${chip}, subcommand: ${subcommand})"
      return 0
    fi
  done

  reason="$(tail -n 2 "${error_log}" 2>/dev/null | tr '\n' ' ' || true)"
  rm -f "${error_log}" "${env_dir}/${merged}"
  warn "merged image skipped for ${env_name}: esptool could not merge images (${reason:-unknown error})"
  return 0
}

rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}"

resolve_esptool
if [[ -z "${ESPTOOL_KIND}" ]]; then
  warn "esptool not found: merged images will be skipped, per-image bins are still bundled"
fi

collected_envs=0

for env_path in "${BUILD_ROOT}"/*; do
  [[ -d "${env_path}" ]] || continue
  env_name="$(basename "${env_path}")"

  firmware_candidate=""
  for candidate in firmware.bin firmware.hex firmware.uf2; do
    if [[ -f "${env_path}/${candidate}" ]]; then
      firmware_candidate="${candidate}"
      break
    fi
  done
  [[ -n "${firmware_candidate}" ]] || continue

  env_out="${BUNDLE_DIR}/${env_name}"
  mkdir -p "${env_out}"
  note "Collecting ${env_name} (${firmware_candidate})"

  for file in firmware.bin firmware.hex firmware.uf2 firmware.elf \
    bootloader.bin partitions.bin boot_app0.bin; do
    copy_if_exists "${env_path}/${file}" "${env_out}/${file}"
  done

  board="$(get_env_value "${PROJECT_DIR}/platformio.ini" 'board' "${env_name}")"
  platform_raw="$(get_env_value "${PROJECT_DIR}/platformio.ini" 'platform' "${env_name}")"
  platform_name="${platform_raw%%@*}"
  platform_name="${platform_name//[[:space:]]/}"
  if [[ -z "${platform_name}" ]]; then
    platform_name="espressif32"
  fi
  chip="$(detect_chip "${board}" "${platform_name}")"
  chip="${chip//[[:space:]]/}"

  # Arduino ESP32 builds do not always drop boot_app0.bin into the build dir;
  # take it from the framework package so the bundle can initialise otadata.
  if [[ ! -f "${env_out}/boot_app0.bin" && "${platform_name}" == espressif32* ]]; then
    boot_app0_src="$(find_boot_app0)"
    if [[ -n "${boot_app0_src}" ]]; then
      copy_if_exists "${boot_app0_src}" "${env_out}/boot_app0.bin"
    else
      warn "boot_app0.bin not found under ${PIO_CORE}/packages (framework-arduinoespressif32/tools/partitions)"
    fi
  fi

  create_merged_image "${env_out}" "${env_name}" "${chip}" "${board}"

  flash_lines=()
  flash_lines+=("# env: ${env_name}    board: ${board:-unknown}    chip: ${chip:-unknown}")
  flash_lines+=("# 烧录端口请替换 -p 后面的参数（Windows 例如 COM5，Linux/macOS 例如 /dev/ttyUSB0）")

  if [[ -f "${env_out}/merged-0x0.bin" ]]; then
    flash_lines+=("")
    flash_lines+=("# 方式一（推荐）：单文件镜像，从 0x0 开始写入（含 bootloader/分区表/boot_app0/应用）")
    flash_lines+=("esptool.py --chip ${chip} -p COM_PORT -b 460800 write_flash 0x0 merged-0x0.bin")
    flash_lines+=("")
    flash_lines+=("# 方式二：分段镜像，与 ESP-IDF/PlatformIO 默认布局一致")
  fi

  if [[ -f "${env_out}/bootloader.bin" && -f "${env_out}/partitions.bin" && -f "${env_out}/firmware.bin" ]]; then
    individual="esptool.py --chip ${chip:-esp32} -p COM_PORT -b 460800 write_flash $(bootloader_offset "${chip}") bootloader.bin 0x8000 partitions.bin"
    if [[ -f "${env_out}/boot_app0.bin" ]]; then
      individual="${individual} 0xe000 boot_app0.bin"
    fi
    individual="${individual} 0x10000 firmware.bin"
    flash_lines+=("${individual}")
    flash_lines+=("# 注意：0xe000 的 boot_app0.bin 会初始化 otadata，让 bootloader 启动本次写入的 app0；")
    flash_lines+=("#       若设备之前跑过其他 OTA 固件而少了这一步，可能仍启动旧的 app1。")
  elif [[ -f "${env_out}/firmware.bin" ]]; then
    flash_lines+=("")
    flash_lines+=("# 该环境（${platform_name}）直接把 firmware.bin 写到 0x0")
    flash_lines+=("esptool.py --chip ${chip:-esp8266} -p COM_PORT -b 460800 write_flash 0x0 firmware.bin")
  elif [[ -f "${env_out}/firmware.hex" ]]; then
    flash_lines+=("")
    flash_lines+=("# AVR 等平台请使用 avrdude 烧录 firmware.hex")
    flash_lines+=("avrdude -p <mcu> -c <programmer> -P <port> -U flash:w:firmware.hex:i")
  elif [[ -f "${env_out}/firmware.uf2" ]]; then
    flash_lines+=("")
    flash_lines+=("# 将开发板置于 BOOTSEL/UF2 模式后，直接把 firmware.uf2 复制到对应磁盘")
  fi

  flash_lines+=("")
  flash_lines+=("# 设备此前运行过 OTA 固件、不确定启动哪个分区时，先擦除 otadata：")
  flash_lines+=("#   esptool.py --chip ${chip:-esp32} -p COM_PORT erase_region 0xe000 0x2000")
  flash_lines+=("# 需要擦除整片 flash：esptool.py --chip ${chip:-esp32} -p COM_PORT erase_flash")
  printf '%s\n' "${flash_lines[@]}" > "${env_out}/flash_args.txt"

  collected_envs=$((collected_envs + 1))
done

if [[ "${collected_envs}" -eq 0 ]]; then
  printf 'No firmware images found under %s\n' "${BUILD_ROOT}" >&2
  exit 1
fi

{
  echo "Arduino / PlatformIO build bundle"
  echo "generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "environments: ${collected_envs}"
  echo
  echo "Contents:"
  for env_dir in "${BUNDLE_DIR}"/*/; do
    [[ -d "${env_dir}" ]] || continue
    echo "- $(basename "${env_dir}")"
    for file in "${env_dir}"*; do
      [[ -f "${file}" ]] || continue
      printf '    %-20s %8s bytes\n' "$(basename "${file}")" "$(wc -c < "${file}")"
    done
  done
  echo
  echo "See <env>/flash_args.txt for ready-to-use flashing commands."
  echo "The zip is password protected; use the password shown on the compile web page."
} > "${BUNDLE_DIR}/BUILD-INFO.txt"

echo
echo "Bundle ready: ${BUNDLE_DIR} (${collected_envs} environment(s))"
