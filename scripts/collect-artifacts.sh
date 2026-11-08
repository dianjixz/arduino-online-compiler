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
#   ESPTOOL_PY           explicit path to esptool.py (auto-discovered otherwise)
#   PYTHON_BIN           python interpreter to use (default: python3, then python)
set -euo pipefail

PROJECT_DIR="${1:?usage: collect-artifacts.sh <project-dir> <bundle-dir>}"
BUNDLE_DIR="${2:?usage: collect-artifacts.sh <project-dir> <bundle-dir>}"

BUILD_ROOT="${PROJECT_DIR}/.pio/build"
PIO_CORE="${PLATFORMIO_CORE_DIR:-${HOME}/.platformio}"

if [[ ! -d "${BUILD_ROOT}" ]]; then
  echo "PlatformIO build directory not found: ${BUILD_ROOT}" >&2
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

detect_chip() {
  local board="$1" platform_name="$2"
  [[ -n "${board}" && -n "${PYTHON_BIN}" ]] || return 0
  local board_json="${PIO_CORE}/platforms/${platform_name}/boards/${board}.json"
  [[ -f "${board_json}" ]] || return 0
  "${PYTHON_BIN}" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("build", {}).get("mcu", ""))' "${board_json}" 2>/dev/null || true
}

bootloader_offset() {
  case "$1" in
    esp32 | esp32s2) printf '0x1000' ;;
    esp32s3 | esp32c3 | esp32c2 | esp32c6 | esp32h2 | esp32p4) printf '0x0' ;;
    *) printf '' ;;
  esac
}

find_esptool() {
  if [[ -n "${ESPTOOL_PY:-}" && -f "${ESPTOOL_PY}" ]]; then
    printf '%s' "${ESPTOOL_PY}"
    return 0
  fi
  [[ -d "${PIO_CORE}/packages" ]] || return 0
  find "${PIO_CORE}/packages" -maxdepth 3 -type f -name 'esptool.py' -print -quit 2>/dev/null || true
}

copy_if_exists() {
  [[ -f "$1" ]] || return 0
  cp "$1" "$2"
  printf '  + %s\n' "$(basename "$2")"
}

rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}"

ESPTOOL_SCRIPT="$(find_esptool)"
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
  echo "Collecting ${env_name} (${firmware_candidate})"

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

  flash_lines=()
  flash_lines+=("# env: ${env_name}    board: ${board:-unknown}    chip: ${chip:-unknown}")
  flash_lines+=("# 烧录端口请替换 -p 后面的参数（Windows 例如 COM5，Linux/macOS 例如 /dev/ttyUSB0）")

  merged_written=0
  if [[ -f "${env_out}/bootloader.bin" && -f "${env_out}/partitions.bin" && -f "${env_out}/firmware.bin" ]]; then
    boot_off="$(bootloader_offset "${chip}")"
    if [[ -n "${boot_off}" && -n "${ESPTOOL_SCRIPT}" && -n "${PYTHON_BIN}" ]]; then
      merge_args=(--chip "${chip}" merge_bin -o merged-0x0.bin --flash_mode keep --flash_freq keep --flash_size keep)
      merge_args+=("${boot_off}" bootloader.bin 0x8000 partitions.bin)
      if [[ -f "${env_out}/boot_app0.bin" ]]; then
        merge_args+=(0xe000 boot_app0.bin)
      fi
      merge_args+=(0x10000 firmware.bin)
      if (
        cd "${env_out}"
        "${PYTHON_BIN}" "${ESPTOOL_SCRIPT}" "${merge_args[@]}" >/dev/null 2>&1
      ); then
        merged_written=1
        echo "  + merged-0x0.bin (chip: ${chip})"
      else
        rm -f "${env_out}/merged-0x0.bin"
        echo "Warning: esptool merge_bin failed for ${env_name}; individual images are still bundled." >&2
      fi
    fi
  fi

  if [[ "${merged_written}" -eq 1 ]]; then
    flash_lines+=("")
    flash_lines+=("# 方式一（推荐）：单文件镜像，从 0x0 开始写入")
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
  flash_lines+=("# ESP32 系列如需擦除整片 flash：esptool.py --chip ${chip:-esp32} -p COM_PORT erase_flash")
  printf '%s\n' "${flash_lines[@]}" > "${env_out}/flash_args.txt"

  collected_envs=$((collected_envs + 1))
done

if [[ "${collected_envs}" -eq 0 ]]; then
  echo "No firmware images found under ${BUILD_ROOT}" >&2
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
