#!/usr/bin/env bash
# convert_debs.sh — Extract, patch, and ad-hoc sign iOS .dylibs from .deb packages.
# Designed for macos-latest GitHub Actions runners (otool, install_name_tool, lipo, codesign).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEBS_DIR="${REPO_ROOT}/debs"
DYLIBS_DIR="${REPO_ROOT}/dylibs"
WORKDIR_ROOT=""

log()  { printf '[convert] %s\n' "$*"; }
warn() { printf '[convert] WARN: %s\n' "$*" >&2; }
die()  { printf '[convert] ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${WORKDIR_ROOT}" && -d "${WORKDIR_ROOT}" ]]; then
    rm -rf "${WORKDIR_ROOT}"
  fi
}
trap cleanup EXIT

mkdir -p "${DYLIBS_DIR}" "${DEBS_DIR}"

# ---------------------------------------------------------------------------
# Collect .deb inputs from repo root and debs/
# ---------------------------------------------------------------------------
collect_debs() {
  local -a found=()
  local f
  shopt -s nullglob
  for f in "${REPO_ROOT}"/*.deb "${DEBS_DIR}"/*.deb; do
    [[ -f "${f}" ]] || continue
    found+=("${f}")
  done
  shopt -u nullglob
  if ((${#found[@]} == 0)); then
    log "No .deb files found in repo root or debs/. Nothing to do."
    exit 0
  fi
  printf '%s\n' "${found[@]}"
}

# ---------------------------------------------------------------------------
# Extract data.tar.* from a .deb into payload/
# ---------------------------------------------------------------------------
extract_deb_payload() {
  local deb_path="$1"
  local workdir="$2"
  local payload="${workdir}/payload"
  mkdir -p "${workdir}/ar" "${payload}"

  (
    cd "${workdir}/ar"
    ar -x "${deb_path}"
  )

  local data_tar=""
  shopt -s nullglob
  local candidates=("${workdir}/ar"/data.tar.*)
  shopt -u nullglob
  if ((${#candidates[@]} == 0)); then
    die "No data.tar.* found inside $(basename "${deb_path}")"
  fi
  data_tar="${candidates[0]}"

  case "${data_tar}" in
    *.tar.gz|*.tar.gzip)
      tar -xzf "${data_tar}" -C "${payload}"
      ;;
    *.tar.xz)
      tar -xJf "${data_tar}" -C "${payload}"
      ;;
    *.tar.zst|*.tar.zstd)
      if command -v zstd >/dev/null 2>&1; then
        zstd -dc "${data_tar}" | tar -xf - -C "${payload}"
      else
        tar --use-compress-program=zstd -xf "${data_tar}" -C "${payload}"
      fi
      ;;
    *.tar.bz2|*.tar.bzip2)
      tar -xjf "${data_tar}" -C "${payload}"
      ;;
    *.tar.lzma)
      if command -v xz >/dev/null 2>&1; then
        xz -dc --format=lzma "${data_tar}" | tar -xf - -C "${payload}"
      else
        tar --lzma -xf "${data_tar}" -C "${payload}"
      fi
      ;;
    *.tar)
      tar -xf "${data_tar}" -C "${payload}"
      ;;
    *)
      # Fallback: try GNU tar auto-detect
      if ! tar -xf "${data_tar}" -C "${payload}" 2>/dev/null; then
        die "Unsupported data.tar compression: $(basename "${data_tar}")"
      fi
      ;;
  esac

  printf '%s\n' "${payload}"
}

# ---------------------------------------------------------------------------
# Discover Mach-O dylib candidates under payload/
# ---------------------------------------------------------------------------
is_macho() {
  local path="$1"
  local info
  info="$(file -b "${path}" 2>/dev/null || true)"
  [[ "${info}" == *"Mach-O"* ]]
}

discover_dylibs() {
  local payload="$1"
  local -a results=()
  local f

  # Explicit .dylib files
  while IFS= read -r -d '' f; do
    if is_macho "${f}"; then
      results+=("${f}")
    fi
  done < <(find "${payload}" -type f -name '*.dylib' -print0 2>/dev/null)

  # Extensionless Mach-O binaries inside DynamicLibraries or .framework
  while IFS= read -r -d '' f; do
    local base
    base="$(basename "${f}")"
    # Skip already-collected .dylib and common non-binaries
    [[ "${base}" == *.dylib ]] && continue
    [[ "${base}" == *.plist || "${base}" == *.txt || "${base}" == *.md ]] && continue
    if is_macho "${f}"; then
      results+=("${f}")
    fi
  done < <(find "${payload}" \( \
      -path '*/DynamicLibraries/*' -o \
      -path '*/.framework/*' -o \
      -path '*/Frameworks/*' \
    \) -type f ! -name '*.dylib' ! -name '*.plist' ! -name '*.txt' -print0 2>/dev/null)

  if ((${#results[@]} == 0)); then
    return 0
  fi
  printf '%s\n' "${results[@]}"
}

# ---------------------------------------------------------------------------
# Ensure arm64 (or arm64e) slice
# ---------------------------------------------------------------------------
ensure_arm64_slice() {
  local src="$1"
  local dest="$2"
  local info
  info="$(lipo -info "${src}" 2>/dev/null || true)"

  if [[ -z "${info}" ]]; then
    warn "lipo -info failed for ${src}; copying as-is"
    cp -f "${src}" "${dest}"
    return 0
  fi

  # Non-fat: already a single architecture
  if [[ "${info}" == *"is architecture:"* ]] || [[ "${info}" != *"Architectures in the fat file"* && "${info}" != *"Non-fat"* ]]; then
    # lipo -info formats:
    #   Non-fat file: <path> is architecture: arm64
    #   Architectures in the fat file: <path> are: armv7 arm64
    :
  fi

  if echo "${info}" | grep -qE '\barm64e\b' && ! echo "${info}" | grep -qE '\barm64\b'; then
    warn "$(basename "${src}"): only arm64e present; keeping arm64e"
    if echo "${info}" | grep -qi 'fat file'; then
      lipo -thin arm64e "${src}" -output "${dest}" 2>/dev/null || cp -f "${src}" "${dest}"
    else
      cp -f "${src}" "${dest}"
    fi
    return 0
  fi

  if echo "${info}" | grep -qE '\barm64\b'; then
    if echo "${info}" | grep -qi 'fat file'; then
      # Prefer thin arm64 for sideloading; fall back to keeping fat if thin fails
      if lipo -thin arm64 "${src}" -output "${dest}" 2>/dev/null; then
        log "Thinned $(basename "${src}") to arm64"
      else
        cp -f "${src}" "${dest}"
      fi
    else
      cp -f "${src}" "${dest}"
    fi
    return 0
  fi

  warn "$(basename "${src}"): no arm64/arm64e slice found (${info}); skipping"
  return 1
}

# ---------------------------------------------------------------------------
# Rewrite load commands for jailed injection
# ---------------------------------------------------------------------------
SUBSTRATE_RPATH='@rpath/CydiaSubstrate.framework/CydiaSubstrate'

rewrite_substrate_deps() {
  local target="$1"
  local dep old_path

  # Collect unique linked paths (skip the first line which is the binary itself for otool -L)
  while IFS= read -r line; do
    # otool -L lines look like: "\t/path/to/lib (compatibility version ...)"
    old_path="$(echo "${line}" | sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//; s/ \(version.*$//')"
    [[ -z "${old_path}" ]] && continue
    [[ "${old_path}" == "${target}" ]] && continue
    # Skip the install-name line that matches the file itself when otool prints it
    case "${old_path}" in
      /Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate|\
      /var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate|\
      /usr/lib/libsubstrate.dylib|\
      /var/jb/usr/lib/libsubstrate.dylib|\
      /var/jb/usr/lib/libellekit.dylib|\
      /Library/Frameworks/CydiaSubstrate.framework/Versions/A/CydiaSubstrate|\
      /var/jb/Library/Frameworks/CydiaSubstrate.framework/Versions/A/CydiaSubstrate|\
      @rpath/libellekit.dylib|\
      @rpath/libsubstrate.dylib)
        log "  Remap: ${old_path} -> ${SUBSTRATE_RPATH}"
        install_name_tool -change "${old_path}" "${SUBSTRATE_RPATH}" "${target}" 2>/dev/null || \
          warn "  install_name_tool -change failed for ${old_path}"
        ;;
    esac
  done < <(otool -L "${target}" 2>/dev/null | tail -n +2)
}

rewrite_sibling_deps() {
  local target="$1"
  shift
  local -a siblings=("$@")
  local sib sib_base old_path

  for sib in "${siblings[@]}"; do
    sib_base="$(basename "${sib}")"
    # Match absolute or relative references to sibling dylibs
    while IFS= read -r line; do
      old_path="$(echo "${line}" | sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//; s/ \(version.*$//')"
      [[ -z "${old_path}" ]] && continue
      local old_base
      old_base="$(basename "${old_path}")"
      if [[ "${old_base}" == "${sib_base}" && "${old_path}" != "@rpath/${sib_base}" ]]; then
        # Only rewrite if it looks like a packaged/jailbreak path (not already @rpath/@executable_path)
        case "${old_path}" in
          @rpath/*|@executable_path/*|@loader_path/*) ;;
          *)
            log "  Sibling remap: ${old_path} -> @rpath/${sib_base}"
            install_name_tool -change "${old_path}" "@rpath/${sib_base}" "${target}" 2>/dev/null || \
              warn "  sibling -change failed for ${old_path}"
            ;;
        esac
      fi
    done < <(otool -L "${target}" 2>/dev/null | tail -n +2)
  done
}

adhoc_sign() {
  local target="$1"
  codesign --remove-signature "${target}" 2>/dev/null || true
  if command -v ldid >/dev/null 2>&1; then
    ldid -S "${target}" 2>/dev/null || warn "ldid -S failed for $(basename "${target}")"
  fi
  codesign -f -s - "${target}" 2>/dev/null || warn "codesign ad-hoc failed for $(basename "${target}")"
}

unique_output_path() {
  local preferred="$1"
  local deb_base="$2"
  local out="${DYLIBS_DIR}/${preferred}"
  if [[ -e "${out}" ]]; then
    out="${DYLIBS_DIR}/${deb_base}_${preferred}"
  fi
  # If still colliding, append a counter
  local n=2
  local candidate="${out}"
  while [[ -e "${candidate}" ]]; do
    local stem ext
    stem="${out%.dylib}"
    ext="dylib"
    if [[ "${out}" == *.dylib ]]; then
      candidate="${stem}_${n}.${ext}"
    else
      candidate="${out}_${n}"
    fi
    n=$((n + 1))
  done
  printf '%s\n' "${candidate}"
}

write_info_report() {
  local dylib_path="$1"
  local info_path="${dylib_path}.info.txt"
  {
    echo "=== lipo -info ==="
    lipo -info "${dylib_path}" 2>&1 || true
    echo
    echo "=== otool -L ==="
    otool -L "${dylib_path}" 2>&1 || true
    echo
    echo "=== codesign -dv ==="
    codesign -dv "${dylib_path}" 2>&1 || true
  } > "${info_path}"
  log "Wrote metadata: $(basename "${info_path}")"
}

# ---------------------------------------------------------------------------
# Process one .deb
# ---------------------------------------------------------------------------
process_deb() {
  local deb_path="$1"
  local deb_name deb_base workdir payload
  deb_name="$(basename "${deb_path}")"
  deb_base="${deb_name%.deb}"
  workdir="$(mktemp -d "${WORKDIR_ROOT}/deb.XXXXXX")"

  log "Processing ${deb_name}"
  payload="$(extract_deb_payload "${deb_path}" "${workdir}")"

  local -a found=()
  local line
  while IFS= read -r line; do
    [[ -n "${line}" ]] && found+=("${line}")
  done < <(discover_dylibs "${payload}")

  if ((${#found[@]} == 0)); then
    warn "No Mach-O dylibs found in ${deb_name}"
    return 0
  fi

  log "Found ${#found[@]} Mach-O candidate(s) in ${deb_name}"

  # Stage thinned copies and collect output basenames for sibling remaps
  local -a staged=()
  local -a staged_names=()
  local src dest name
  local stage_dir="${workdir}/staged"
  mkdir -p "${stage_dir}"

  for src in "${found[@]}"; do
    name="$(basename "${src}")"
    # Ensure .dylib extension for extensionless framework binaries
    if [[ "${name}" != *.dylib ]]; then
      name="${name}.dylib"
    fi
    dest="${stage_dir}/${name}"
    # Avoid stage collisions
    local i=2
    while [[ -e "${dest}" ]]; do
      dest="${stage_dir}/${name%.dylib}_${i}.dylib"
      i=$((i + 1))
    done
    if ensure_arm64_slice "${src}" "${dest}"; then
      staged+=("${dest}")
      staged_names+=("$(basename "${dest}")")
    fi
  done

  if ((${#staged[@]} == 0)); then
    warn "No arm64/arm64e dylibs retained from ${deb_name}"
    return 0
  fi

  for dest in "${staged[@]}"; do
    name="$(basename "${dest}")"
    log "Patching ${name}"
    install_name_tool -id "@rpath/${name}" "${dest}" 2>/dev/null || \
      warn "  install_name_tool -id failed for ${name}"
    rewrite_substrate_deps "${dest}"
    rewrite_sibling_deps "${dest}" "${staged[@]}"
    adhoc_sign "${dest}"

    local out_path
    out_path="$(unique_output_path "${name}" "${deb_base}")"
    cp -f "${dest}" "${out_path}"
    log "Output: ${out_path#"${REPO_ROOT}/"}"
    write_info_report "${out_path}"
  done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  WORKDIR_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/deb-dylib.XXXXXX")"
  log "Repo root: ${REPO_ROOT}"
  log "Output dir: ${DYLIBS_DIR}"

  local -a debs=()
  local d
  while IFS= read -r d; do
    [[ -n "${d}" ]] && debs+=("${d}")
  done < <(collect_debs)

  log "Found ${#debs[@]} .deb package(s)"
  for d in "${debs[@]}"; do
    process_deb "${d}"
  done

  log "Done."
}

main "$@"
