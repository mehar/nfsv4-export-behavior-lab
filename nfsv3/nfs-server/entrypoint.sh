#!/usr/bin/env bash
set -euo pipefail

EXPORT_ROOT="${EXPORT_ROOT:-/exports}"
EXPORT_HOSTS="${EXPORT_HOSTS:-*}"
PSEUDO_ROOT_SQUASH="${PSEUDO_ROOT_SQUASH:-root_squash}"
EXPORT_SET="${EXPORT_SET:-all}"
ANON_PROFILE_FILTER="${ANON_PROFILE_FILTER:-all}"
PSEUDO_ROOT_ANON_PROFILE="${PSEUDO_ROOT_ANON_PROFILE:-${ANON_PROFILE_FILTER}}"

owners=("root" "ccexportuser")
permissions=("777" "755" "644" "600" "700" "444")
squash_modes=("all_squash" "root_squash" "no_squash")
anon_profiles=("ubuntu" "redhat" "windows")
next_fsid=1

mkdir -p "${EXPORT_ROOT}"
case "${PSEUDO_ROOT_SQUASH}" in
  root_squash)
    pseudo_root_squash_opt="root_squash"
    ;;
  all_squash)
    pseudo_root_squash_opt="all_squash"
    ;;
  no_root_squash)
    pseudo_root_squash_opt="no_root_squash"
    ;;
  *)
    echo "Unsupported PSEUDO_ROOT_SQUASH value: ${PSEUDO_ROOT_SQUASH}"
    echo "Supported values: root_squash, all_squash, no_root_squash"
    exit 1
    ;;
esac

anon_ids_for_profile() {
  local anon_profile="$1"
  case "${anon_profile}" in
    ubuntu)
      anon_uid=65534
      anon_gid=65534
      ;;
    redhat)
      anon_uid=65533
      anon_gid=65533
      ;;
    windows)
      anon_uid=65532
      anon_gid=65532
      ;;
    *)
      echo "Unsupported anonymous profile: ${anon_profile}"
      echo "Supported values: ubuntu, redhat, windows"
      exit 1
      ;;
  esac
}

should_export_squash_mode() {
  local mode="$1"
  case "${EXPORT_SET}" in
    all)
      return 0
      ;;
    all_squash_only)
      [ "${mode}" = "all_squash" ]
      return
      ;;
    root_squash_only)
      [ "${mode}" = "root_squash" ]
      return
      ;;
    no_squash_only)
      [ "${mode}" = "no_squash" ]
      return
      ;;
    *)
      echo "Unsupported EXPORT_SET value: ${EXPORT_SET}"
      echo "Supported values: all, all_squash_only, root_squash_only, no_squash_only"
      exit 1
      ;;
  esac
}

should_export_anon_profile() {
  local anon_profile="$1"
  case "${ANON_PROFILE_FILTER}" in
    all)
      return 0
      ;;
    ubuntu|redhat|windows)
      [ "${anon_profile}" = "${ANON_PROFILE_FILTER}" ]
      return
      ;;
    *)
      echo "Unsupported ANON_PROFILE_FILTER value: ${ANON_PROFILE_FILTER}"
      echo "Supported values: all, ubuntu, redhat, windows"
      exit 1
      ;;
  esac
}

pseudo_root_extra_opts=""
if [ "${pseudo_root_squash_opt}" = "all_squash" ]; then
  pseudo_profile="${PSEUDO_ROOT_ANON_PROFILE}"
  if [ "${pseudo_profile}" = "all" ]; then
    # fsid=0 needs a single anon mapping; default to ubuntu nobody.
    pseudo_profile="ubuntu"
  fi
  anon_ids_for_profile "${pseudo_profile}"
  pseudo_root_extra_opts=",anonuid=${anon_uid},anongid=${anon_gid}"
fi

{
  echo "${EXPORT_ROOT} ${EXPORT_HOSTS}(rw,async,no_subtree_check,insecure,fsid=0,crossmnt,${pseudo_root_squash_opt}${pseudo_root_extra_opts})"
} > /etc/exports

for owner in "${owners[@]}"; do
  for perm in "${permissions[@]}"; do
    for squash_mode in "${squash_modes[@]}"; do
      if ! should_export_squash_mode "${squash_mode}"; then
        continue
      fi
      if [ "${squash_mode}" = "no_squash" ]; then
        export_dir="${EXPORT_ROOT}/owner_${owner}_perm_${perm}_squash_${squash_mode}"
        mkdir -p "${export_dir}"
        chown "${owner}:${owner}" "${export_dir}"
        chmod "${perm}" "${export_dir}"
        echo "owner=${owner} mode=${perm} squash=${squash_mode} anon_profile=none" > "${export_dir}/README.txt"
        echo "${export_dir} ${EXPORT_HOSTS}(rw,async,no_subtree_check,no_root_squash,insecure,fsid=${next_fsid})" >> /etc/exports
        next_fsid=$((next_fsid + 1))
        continue
      fi

      for anon_profile in "${anon_profiles[@]}"; do
        if ! should_export_anon_profile "${anon_profile}"; then
          continue
        fi
        export_dir="${EXPORT_ROOT}/owner_${owner}_perm_${perm}_squash_${squash_mode}_anon_${anon_profile}"
        mkdir -p "${export_dir}"
        chown "${owner}:${owner}" "${export_dir}"
        chmod "${perm}" "${export_dir}"

        case "${squash_mode}" in
          all_squash)
            squash_opt="all_squash"
            ;;
          root_squash)
            squash_opt="root_squash"
            ;;
          *)
            echo "Unsupported squash mode: ${squash_mode}"
            exit 1
            ;;
        esac

        anon_ids_for_profile "${anon_profile}"

        echo "owner=${owner} mode=${perm} squash=${squash_mode} anon_profile=${anon_profile} anon_uid=${anon_uid} anon_gid=${anon_gid}" > "${export_dir}/README.txt"
        echo "${export_dir} ${EXPORT_HOSTS}(rw,async,no_subtree_check,${squash_opt},anonuid=${anon_uid},anongid=${anon_gid},insecure,fsid=${next_fsid})" >> /etc/exports
        next_fsid=$((next_fsid + 1))
      done
    done
  done
done

echo "Generated exports:"
ls -1 "${EXPORT_ROOT}" | sed 's/^/ - /'

mkdir -p /proc/fs/nfsd /run/rpcbind
mount -t nfsd nfsd /proc/fs/nfsd || true

rpcbind -w
exportfs -rav

# Start NFS daemon with NFSv4 disabled (NFSv3-only in this environment).
rpc.nfsd -N 4 8
# Keep mountd running for kernel export/auth upcalls.
rpc.mountd -F &

exec tail -f /dev/null
