#!/usr/bin/env bash
set -euo pipefail

NFS_SERVERS="${NFS_SERVERS:-root_squash=nfs-server-root-squash,all_squash_ubuntu=nfs-server-all-squash-ubuntu,all_squash_redhat=nfs-server-all-squash-redhat,all_squash_windows=nfs-server-all-squash-windows,no_root_squash=nfs-server-no-root-squash}"
MOUNT_BASE="${MOUNT_BASE:-/mnt/nfs}"
NFS_EXPORT_BASE="${NFS_EXPORT_BASE:-/}"
MOUNT_OPTS="${MOUNT_OPTS:-vers=4,soft,timeo=50,retrans=2}"
MOUNT_RETRIES="${MOUNT_RETRIES:-60}"
RETRY_INTERVAL_SEC="${RETRY_INTERVAL_SEC:-2}"

owners=("root" "ccexportuser" "ubuntu_anon")
permissions=("777" "755" "644" "600" "700" "444")
squash_modes=("all_squash" "root_squash" "no_squash")
anon_profiles=("ubuntu" "redhat" "windows")

mkdir -p "${MOUNT_BASE}"

# For NFSv4, mounts resolve from the server pseudo-root (fsid=0), so
# using /exports as a client-side base path causes "No such file or directory".
if [[ "${MOUNT_OPTS}" == *"vers=4"* ]] && [ "${NFS_EXPORT_BASE}" = "/exports" ]; then
  echo "NFSv4 detected with NFS_EXPORT_BASE=/exports; normalizing to / for pseudo-root pathing."
  NFS_EXPORT_BASE="/"
fi

IFS=',' read -r -a server_entries <<< "${NFS_SERVERS}"
root_squash_server=""
all_squash_server=""
all_squash_ubuntu_server=""
all_squash_redhat_server=""
all_squash_windows_server=""
no_root_squash_server=""

for server_entry in "${server_entries[@]}"; do
  [ -n "${server_entry}" ] || continue
  if [[ "${server_entry}" != *=* ]]; then
    echo "Invalid NFS_SERVERS entry: ${server_entry}"
    echo "Expected format: <label>=<hostname>[,<label>=<hostname>...]"
    exit 1
  fi

  server_label="${server_entry%%=*}"
  server_host="${server_entry#*=}"
  case "${server_label}" in
    root_squash)
      root_squash_server="${server_host}"
      ;;
    all_squash)
      all_squash_server="${server_host}"
      ;;
    all_squash_ubuntu)
      all_squash_ubuntu_server="${server_host}"
      ;;
    all_squash_redhat)
      all_squash_redhat_server="${server_host}"
      ;;
    all_squash_windows)
      all_squash_windows_server="${server_host}"
      ;;
    no_root_squash)
      no_root_squash_server="${server_host}"
      ;;
  esac

  echo "Waiting for NFS server ${server_label} (${server_host}):2049 ..."
  until nc -z "${server_host}" 2049; do
    sleep 1
  done
done

if [ -z "${root_squash_server}" ]; then
  echo "NFS_SERVERS must include root_squash=<hostname>"
  exit 1
fi

select_server_for_export() {
  local export_name="$1"
  if [[ "${export_name}" == *_squash_all_squash_anon_ubuntu ]]; then
    if [ -n "${all_squash_ubuntu_server}" ]; then
      printf "%s" "${all_squash_ubuntu_server}"
      return
    fi
  elif [[ "${export_name}" == *_squash_all_squash_anon_redhat ]]; then
    if [ -n "${all_squash_redhat_server}" ]; then
      printf "%s" "${all_squash_redhat_server}"
      return
    fi
  elif [[ "${export_name}" == *_squash_all_squash_anon_windows ]]; then
    if [ -n "${all_squash_windows_server}" ]; then
      printf "%s" "${all_squash_windows_server}"
      return
    fi
  fi

  if [[ "${export_name}" == *_squash_all_squash_anon_* ]]; then
    if [ -n "${all_squash_server}" ]; then
      printf "%s" "${all_squash_server}"
      return
    fi
    echo "WARNING: all_squash server not configured; falling back to root_squash server for ${export_name}" >&2
    printf "%s" "${root_squash_server}"
    return
  fi

  if [[ "${export_name}" == *_squash_no_squash ]]; then
    if [ -n "${no_root_squash_server}" ]; then
      printf "%s" "${no_root_squash_server}"
      return
    fi
    echo "WARNING: no_root_squash server not configured; falling back to root_squash server for ${export_name}" >&2
    printf "%s" "${root_squash_server}"
    return
  fi

  printf "%s" "${root_squash_server}"
}

for owner in "${owners[@]}"; do
  for perm in "${permissions[@]}"; do
    for squash_mode in "${squash_modes[@]}"; do
      if [ "${squash_mode}" = "no_squash" ]; then
        export_name="owner_${owner}_perm_${perm}_squash_${squash_mode}"
        if [ "${NFS_EXPORT_BASE}" = "/" ]; then
          remote_path="/${export_name}"
        else
          remote_path="${NFS_EXPORT_BASE%/}/${export_name}"
        fi
        server_host="$(select_server_for_export "${export_name}")"
        mount_point="${MOUNT_BASE}/${export_name}"

        mkdir -p "${mount_point}"

        if mountpoint -q "${mount_point}"; then
          echo "${mount_point} is already mounted"
          continue
        fi

        echo "Mounting ${server_host}:${remote_path} on ${mount_point}"
        attempt=1
        while ! mount -t nfs -o "${MOUNT_OPTS}" "${server_host}:${remote_path}" "${mount_point}"; do
          if [ "${attempt}" -ge "${MOUNT_RETRIES}" ]; then
            echo "Failed to mount ${server_host}:${remote_path} after ${MOUNT_RETRIES} attempts"
            exit 1
          fi
          echo "Mount attempt ${attempt}/${MOUNT_RETRIES} for ${server_host}:${remote_path} failed; retrying in ${RETRY_INTERVAL_SEC}s..."
          attempt=$((attempt + 1))
          sleep "${RETRY_INTERVAL_SEC}"
        done

        echo "Mounted ${server_host}:${remote_path} on ${mount_point}"
        continue
      fi

      for anon_profile in "${anon_profiles[@]}"; do
        export_name="owner_${owner}_perm_${perm}_squash_${squash_mode}_anon_${anon_profile}"
        if [ "${NFS_EXPORT_BASE}" = "/" ]; then
          remote_path="/${export_name}"
        else
          remote_path="${NFS_EXPORT_BASE%/}/${export_name}"
        fi
        server_host="$(select_server_for_export "${export_name}")"
        mount_point="${MOUNT_BASE}/${export_name}"

        mkdir -p "${mount_point}"

        if mountpoint -q "${mount_point}"; then
          echo "${mount_point} is already mounted"
          continue
        fi

        echo "Mounting ${server_host}:${remote_path} on ${mount_point}"
        attempt=1
        while ! mount -t nfs -o "${MOUNT_OPTS}" "${server_host}:${remote_path}" "${mount_point}"; do
          if [ "${attempt}" -ge "${MOUNT_RETRIES}" ]; then
            echo "Failed to mount ${server_host}:${remote_path} after ${MOUNT_RETRIES} attempts"
            exit 1
          fi
          echo "Mount attempt ${attempt}/${MOUNT_RETRIES} for ${server_host}:${remote_path} failed; retrying in ${RETRY_INTERVAL_SEC}s..."
          attempt=$((attempt + 1))
          sleep "${RETRY_INTERVAL_SEC}"
        done

        echo "Mounted ${server_host}:${remote_path} on ${mount_point}"
      done
    done
  done
done

ls -la "${MOUNT_BASE}" || true

exec tail -f /dev/null
