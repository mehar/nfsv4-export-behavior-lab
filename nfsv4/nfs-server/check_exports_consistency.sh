#!/usr/bin/env bash
set -euo pipefail

EXPORT_ROOT="${EXPORT_ROOT:-/exports}"
EXPORTS_FILE="${EXPORTS_FILE:-/etc/exports}"
EXPORT_SET="${EXPORT_SET:-all}"
ANON_PROFILE_FILTER="${ANON_PROFILE_FILTER:-all}"

anon_profile_factor=3
case "${ANON_PROFILE_FILTER}" in
  all)
    anon_profile_factor=3
    ;;
  ubuntu|redhat|windows)
    anon_profile_factor=1
    ;;
  *)
    echo "ERROR: unsupported ANON_PROFILE_FILTER=${ANON_PROFILE_FILTER}"
    echo "Supported: all, ubuntu, redhat, windows"
    exit 2
    ;;
esac

case "${EXPORT_SET}" in
  all)
    expected_per_dir_exports=$((2 * 6 * ((2 * 3) + 1)))
    ;;
  all_squash_only)
    # all_squash (selected anon profiles) per owner/mode
    expected_per_dir_exports=$((2 * 6 * anon_profile_factor))
    ;;
  root_squash_only)
    # root_squash (selected anon profiles) per owner/mode
    expected_per_dir_exports=$((2 * 6 * anon_profile_factor))
    ;;
  no_squash_only)
    # no_squash only per owner/mode
    expected_per_dir_exports=$((2 * 6 * 1))
    ;;
  *)
    echo "ERROR: unsupported EXPORT_SET=${EXPORT_SET}"
    echo "Supported: all, all_squash_only, root_squash_only, no_squash_only"
    exit 2
    ;;
esac

if [ ! -f "${EXPORTS_FILE}" ]; then
  echo "ERROR: exports file not found: ${EXPORTS_FILE}"
  exit 2
fi

mismatches=0
checked=0

declare -A seen_fsid=()

fail() {
  echo "MISMATCH: $*"
  mismatches=$((mismatches + 1))
}

has_opt() {
  local opts="$1"
  local opt="$2"
  case ",${opts}," in
    *,"${opt}",*) return 0 ;;
    *) return 1 ;;
  esac
}

extract_opt_value() {
  local opts="$1"
  local key="$2"
  printf "%s" "${opts}" | sed -n "s/.*${key}=\\([0-9][0-9]*\\).*/\\1/p"
}

# Validate NFSv4 pseudo-root export.
root_line="$(grep -E "^${EXPORT_ROOT}[[:space:]]" "${EXPORTS_FILE}" || true)"
if [ -z "${root_line}" ]; then
  fail "missing root export line for ${EXPORT_ROOT}"
else
  root_opts="${root_line#*\(}"
  root_opts="${root_opts%\)}"
  has_opt "${root_opts}" "fsid=0" || fail "root export missing fsid=0: (${root_opts})"
  has_opt "${root_opts}" "crossmnt" || fail "root export missing crossmnt: (${root_opts})"
fi

while IFS= read -r line; do
  case "${line}" in
    "${EXPORT_ROOT}"/owner_*_perm_*)
      ;;
    *)
      continue
      ;;
  esac

  export_path="${line%% *}"
  opts="${line#*\(}"
  opts="${opts%\)}"
  name="$(basename "${export_path}")"
  checked=$((checked + 1))

  owner="$(printf "%s" "${name}" | sed -n 's/^owner_\([^_]*\)_perm_.*/\1/p')"
  perm="$(printf "%s" "${name}" | sed -n 's/^owner_[^_]*_perm_\([0-9][0-9][0-9]\).*/\1/p')"
  squash_mode="$(printf "%s" "${name}" | sed -n 's/.*_squash_\(all_squash\|root_squash\|no_squash\).*/\1/p')"
  anon_profile="$(printf "%s" "${name}" | sed -n 's/.*_anon_\(ubuntu\|redhat\|windows\)$/\1/p')"

  [ -n "${owner}" ] || fail "${name}: could not parse owner from name"
  [ -n "${perm}" ] || fail "${name}: could not parse mode from name"
  [ -n "${squash_mode}" ] || fail "${name}: could not parse squash mode from name"

  if [ ! -d "${export_path}" ]; then
    fail "${name}: export directory missing at ${export_path}"
    continue
  fi

  actual_owner="$(stat -c "%U" "${export_path}")"
  actual_group="$(stat -c "%G" "${export_path}")"
  actual_perm="$(stat -c "%a" "${export_path}")"

  [ "${actual_owner}" = "${owner}" ] || fail "${name}: owner expected ${owner}, got ${actual_owner}"
  [ "${actual_group}" = "${owner}" ] || fail "${name}: group expected ${owner}, got ${actual_group}"
  [ "${actual_perm}" = "${perm}" ] || fail "${name}: mode expected ${perm}, got ${actual_perm}"

  has_all=0
  has_root=0
  has_noroot=0
  has_opt "${opts}" "all_squash" && has_all=1
  has_opt "${opts}" "root_squash" && has_root=1
  has_opt "${opts}" "no_root_squash" && has_noroot=1

  case "${squash_mode}" in
    all_squash)
      [ "${has_all}" -eq 1 ] || fail "${name}: missing all_squash option (${opts})"
      [ "${has_noroot}" -eq 0 ] || fail "${name}: unexpected no_root_squash with all_squash (${opts})"
      ;;
    root_squash)
      [ "${has_root}" -eq 1 ] || fail "${name}: missing root_squash option (${opts})"
      [ "${has_all}" -eq 0 ] || fail "${name}: unexpected all_squash with root_squash (${opts})"
      [ "${has_noroot}" -eq 0 ] || fail "${name}: unexpected no_root_squash with root_squash (${opts})"
      ;;
    no_squash)
      [ "${has_noroot}" -eq 1 ] || fail "${name}: missing no_root_squash option (${opts})"
      [ "${has_all}" -eq 0 ] || fail "${name}: unexpected all_squash with no_squash (${opts})"
      [ "${has_root}" -eq 0 ] || fail "${name}: unexpected root_squash with no_squash (${opts})"
      ;;
  esac

  anon_uid="$(extract_opt_value "${opts}" "anonuid")"
  anon_gid="$(extract_opt_value "${opts}" "anongid")"

  case "${anon_profile}" in
    ubuntu)
      [ "${anon_uid}" = "65534" ] || fail "${name}: anonuid expected 65534, got ${anon_uid:-none}"
      [ "${anon_gid}" = "65534" ] || fail "${name}: anongid expected 65534, got ${anon_gid:-none}"
      ;;
    redhat)
      [ "${anon_uid}" = "65533" ] || fail "${name}: anonuid expected 65533, got ${anon_uid:-none}"
      [ "${anon_gid}" = "65533" ] || fail "${name}: anongid expected 65533, got ${anon_gid:-none}"
      ;;
    windows)
      [ "${anon_uid}" = "65532" ] || fail "${name}: anonuid expected 65532, got ${anon_uid:-none}"
      [ "${anon_gid}" = "65532" ] || fail "${name}: anongid expected 65532, got ${anon_gid:-none}"
      ;;
    *)
      [ -z "${anon_uid}" ] || fail "${name}: unexpected anonuid=${anon_uid} for no_squash"
      [ -z "${anon_gid}" ] || fail "${name}: unexpected anongid=${anon_gid} for no_squash"
      ;;
  esac

  fsid="$(extract_opt_value "${opts}" "fsid")"
  if [ -z "${fsid}" ]; then
    fail "${name}: missing fsid option"
  else
    if [ "${fsid}" = "0" ]; then
      fail "${name}: fsid=0 is reserved for ${EXPORT_ROOT}"
    fi
    if [ "${seen_fsid[${fsid}]+x}" = "x" ]; then
      fail "${name}: duplicate fsid=${fsid}"
    else
      seen_fsid["${fsid}"]=1
    fi
  fi
done < "${EXPORTS_FILE}"

for i in $(seq 1 "${expected_per_dir_exports}"); do
  if [ "${seen_fsid[${i}]+x}" != "x" ]; then
    fail "missing fsid=${i} (expected contiguous range 1..${expected_per_dir_exports})"
  fi
done

if [ "${checked}" -ne "${expected_per_dir_exports}" ]; then
  fail "expected ${expected_per_dir_exports} per-directory exports, found ${checked}"
fi

echo "CHECKED=${checked}"
echo "MISMATCHES=${mismatches}"

if [ "${mismatches}" -ne 0 ]; then
  exit 1
fi

echo "OK: export ownership, permissions, squash options, anon mapping, and fsid values are consistent."
