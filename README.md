# nfsv4-export-behavior-lab

This setup creates:
1. Ubuntu-based NFSv4 server container with pseudo-root `root_squash`
2. Ubuntu-based NFSv4 server container with pseudo-root `no_root_squash`
3. Ubuntu-based NFSv4 server container for `all_squash` + ubuntu anon mapping (`65534:65534`)
4. Ubuntu-based NFSv4 server container for `all_squash` + redhat anon mapping (`65533:65533`)
5. Ubuntu-based NFSv4 server container for `all_squash` + windows anon mapping (`65532:65532`)
6. Ubuntu-based NFS client container mounting all exports from the appropriate server

## What gets created

Server image users:
- `ccexportuser` uid/gid `1500`

Client image users:
- `root` uid/gid `0`
- `maglev` uid/gid `1234`
- `postgres` uid/gid `1001`
- `mongodb` uid/gid `1002`
- `elasticsearch` uid/gid `1003`

Server export matrix dimensions:
- Owners: `root`, `ccexportuser`
- Permissions: `777`, `755`, `644`, `600`, `700`, `444`
- Squash policies: `all_squash`, `root_squash`, `no_squash`
- Anonymous profiles (used only with `all_squash` and `root_squash`):
  - `ubuntu` anonymous user: `anonuid=65534`, `anongid=65534`
  - `redhat` anonymous user: `anonuid=65533`, `anongid=65533`
  - `windows` anonymous user: `anonuid=65532`, `anongid=65532`

Per-directory exports: `2 * 6 * ((2 * 3) + 1) = 84`
Total `/etc/exports` entries at runtime: `85` (`84` per-directory + `1` NFSv4 pseudo-root `/exports`)

Export naming format:
- With anon profile (`all_squash`, `root_squash`):
  - `owner_<owner>_perm_<mode>_squash_<policy>_anon_<profile>`
- Without anon profile (`no_squash`):
  - `owner_<owner>_perm_<mode>_squash_no_squash`

NFS mount details:
- Server exports directories under `/exports` with per-export squash/anon settings
- Servers run NFSv4 only (NFSv3 disabled in `rpc.nfsd`)
- Each server includes NFSv4 pseudo-root export `/exports` with `fsid=0,crossmnt`
- Per-directory exports are assigned unique `fsid` values (`1..84`) on each server
- `rpc.mountd` is started for kernel export/auth handling in this container environment
- Export routing is intentionally non-overlapping:
  - `root_squash` server exports only `root_squash` entries
  - `all_squash_ubuntu` server exports only `all_squash ... anon_ubuntu` entries
  - `all_squash_redhat` server exports only `all_squash ... anon_redhat` entries
  - `all_squash_windows` server exports only `all_squash ... anon_windows` entries
  - `no_root_squash` server exports only `no_squash` entries
- Client mounts each export under `/mnt/nfs/<export_name>` (no duplicates)
- Client uses NFSv4 direct export paths via `NFS_EXPORT_BASE=/`
- Default server labels:
  - `root_squash` -> `nfs-server-root-squash`
  - `all_squash_ubuntu` -> `nfs-server-all-squash-ubuntu`
  - `all_squash_redhat` -> `nfs-server-all-squash-redhat`
  - `all_squash_windows` -> `nfs-server-all-squash-windows`
  - `no_root_squash` -> `nfs-server-no-root-squash`
- Client mount default options: `vers=4,soft,timeo=50,retrans=2` (override with `MOUNT_OPTS`)

## Why 5-server model

We split this into 5 NFS servers because of how NFSv4 export behavior is applied in this containerized test setup.

Observed behavior:
- Runtime enforcement often collapses to pseudo-root (`fsid=0`) export behavior.
- When that happens, per-directory `all_squash` exports may not reliably preserve distinct `anonuid/anongid` identities.
- This caused false negatives in ownership checks for `all_squash` rows when trying to model ubuntu/redhat/windows anon identities from one server.

Design decision:
- Keep one dedicated server for each `all_squash` anon identity, and set that same identity on the server pseudo-root (`fsid=0`).
- Keep `root_squash` and `no_root_squash` on separate servers.

Result:
- All export classes are non-overlapping.
- Client routing is deterministic per export name.
- The matrix validator now gets stable ownership behavior for all combinations.

## Files
- `nfs-server/Dockerfile`
- `nfs-server/entrypoint.sh`
- `nfs-client/Dockerfile`
- `nfs-client/entrypoint.sh`
- `docker-compose.yml`

## Start
```bash
docker compose up --build -d
```

## Open bash shell in containers
```bash
docker exec -it nfs-server-root-squash bash
docker exec -it nfs-server-all-squash-ubuntu bash
docker exec -it nfs-server-all-squash-redhat bash
docker exec -it nfs-server-all-squash-windows bash
docker exec -it nfs-server-no-root-squash bash
docker exec -it nfs-client bash
```

## Verify server exports
```bash
docker exec -it nfs-server-root-squash ls -la /exports
docker exec -it nfs-server-root-squash cat /etc/exports
docker exec -it nfs-server-all-squash-ubuntu ls -la /exports
docker exec -it nfs-server-all-squash-ubuntu cat /etc/exports
docker exec -it nfs-server-all-squash-redhat ls -la /exports
docker exec -it nfs-server-all-squash-redhat cat /etc/exports
docker exec -it nfs-server-all-squash-windows ls -la /exports
docker exec -it nfs-server-all-squash-windows cat /etc/exports
docker exec -it nfs-server-no-root-squash ls -la /exports
docker exec -it nfs-server-no-root-squash cat /etc/exports
```

## Verify client mounts
```bash
docker exec -it nfs-client mount | grep /mnt/nfs
docker exec -it nfs-client ls -la /mnt/nfs
docker exec -it nfs-client ls -la /mnt/nfs/owner_root_perm_755_squash_root_squash_anon_ubuntu
docker exec -it nfs-client ls -la /mnt/nfs/owner_root_perm_755_squash_no_squash
```

## Validate README Matrix From Client
```bash
docker exec -it nfs-client python3 /usr/local/bin/validate_readme_matrix.py --readme /workspace/README.md --mount-base /mnt/nfs
```

Quick dry run (first 10 rows):
```bash
docker exec -it nfs-client python3 /usr/local/bin/validate_readme_matrix.py --readme /workspace/README.md --mount-base /mnt/nfs --max-rows 10
```

Log format is intentionally direct:
- `EXPECTED`: values from README row
- `WHY`: row comment context
- `READ/WRITE/EXEC/OWNER`: PASS/FAIL for each check
- `RESULT`: per-row final decision
- `SUMMARY`: total failures

## Write/read test
```bash
docker exec -it nfs-client sh -lc 'echo hello-from-client > /mnt/nfs/owner_root_perm_777_squash_no_squash/client-test.txt'
docker exec -it nfs-server-no-root-squash sh -lc 'cat /exports/owner_root_perm_777_squash_no_squash/client-test.txt'
```

## Stop
```bash
docker compose down
```

## NFS Export Access and Ownership Matrix (Learning Reference)

Assumptions used in this table:
- Access checks are evaluated for the directory itself (`/exports/...`), using its Unix mode bits.
- Client users listed are: `root`, `maglev`, `postgres`, `mongodb`, `elasticsearch`.
- `all_squash` maps all client users (including root) to the export's selected anonymous profile UID/GID.
- `root_squash` maps only client root (`0:0`) to the export's selected anonymous profile UID/GID; non-root users keep their UID/GID.
- `no_squash` preserves caller UID/GID and has no anonymous profile.
- "Final owner" means ownership (`uid:gid`) of a newly created file in that export directory.

### owner=root, perm=777

| Export Directory | Client User (uid:gid) | Read | Write | Execute | Final Owner (uid:gid) | Comment |
|---|---|---|---|---|---|---|
| `owner_root_perm_777_squash_all_squash_anon_ubuntu` | `root (0:0)` | allowed | allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_redhat` | `root (0:0)` | allowed | allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_redhat` | `maglev (1234:1234)` | allowed | allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_redhat` | `postgres (1001:1001)` | allowed | allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_windows` | `root (0:0)` | allowed | allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_windows` | `maglev (1234:1234)` | allowed | allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_windows` | `postgres (1001:1001)` | allowed | allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_windows` | `mongodb (1002:1002)` | allowed | allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_root_perm_777_squash_all_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_ubuntu` | `root (0:0)` | allowed | allowed | allowed | `65534:65534` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | allowed | allowed | `1234:1234` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1234:1234; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | allowed | allowed | `1001:1001` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1001:1001; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | allowed | allowed | `1002:1002` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1002:1002; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `1003:1003` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1003:1003; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_redhat` | `root (0:0)` | allowed | allowed | allowed | `65533:65533` | server=root_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_redhat` | `maglev (1234:1234)` | allowed | allowed | allowed | `1234:1234` | server=root_squash,anon=redhat(65533:65533); client mapped to 1234:1234; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_redhat` | `postgres (1001:1001)` | allowed | allowed | allowed | `1001:1001` | server=root_squash,anon=redhat(65533:65533); client mapped to 1001:1001; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | allowed | allowed | `1002:1002` | server=root_squash,anon=redhat(65533:65533); client mapped to 1002:1002; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `1003:1003` | server=root_squash,anon=redhat(65533:65533); client mapped to 1003:1003; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_windows` | `root (0:0)` | allowed | allowed | allowed | `65532:65532` | server=root_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_windows` | `maglev (1234:1234)` | allowed | allowed | allowed | `1234:1234` | server=root_squash,anon=windows(65532:65532); client mapped to 1234:1234; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_windows` | `postgres (1001:1001)` | allowed | allowed | allowed | `1001:1001` | server=root_squash,anon=windows(65532:65532); client mapped to 1001:1001; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_windows` | `mongodb (1002:1002)` | allowed | allowed | allowed | `1002:1002` | server=root_squash,anon=windows(65532:65532); client mapped to 1002:1002; access via owner bits |
| `owner_root_perm_777_squash_root_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `1003:1003` | server=root_squash,anon=windows(65532:65532); client mapped to 1003:1003; access via owner bits |
| `owner_root_perm_777_squash_no_squash` | `root (0:0)` | allowed | allowed | allowed | `0:0` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_root_perm_777_squash_no_squash` | `maglev (1234:1234)` | allowed | allowed | allowed | `1234:1234` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_root_perm_777_squash_no_squash` | `postgres (1001:1001)` | allowed | allowed | allowed | `1001:1001` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_root_perm_777_squash_no_squash` | `mongodb (1002:1002)` | allowed | allowed | allowed | `1002:1002` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_root_perm_777_squash_no_squash` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `1003:1003` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |

### owner=root, perm=755

| Export Directory | Client User (uid:gid) | Read | Write | Execute | Final Owner (uid:gid) | Comment |
|---|---|---|---|---|---|---|
| `owner_root_perm_755_squash_all_squash_anon_ubuntu` | `root (0:0)` | allowed | not allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | not allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | not allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_redhat` | `root (0:0)` | allowed | not allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_redhat` | `maglev (1234:1234)` | allowed | not allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_redhat` | `postgres (1001:1001)` | allowed | not allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_windows` | `root (0:0)` | allowed | not allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_windows` | `maglev (1234:1234)` | allowed | not allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_windows` | `postgres (1001:1001)` | allowed | not allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_windows` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_755_squash_all_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_ubuntu` | `root (0:0)` | allowed | not allowed | allowed | `65534:65534` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | not allowed | allowed | `1234:1234` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1234:1234; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | not allowed | allowed | `1001:1001` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1001:1001; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `1002:1002` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1002:1002; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `1003:1003` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1003:1003; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_redhat` | `root (0:0)` | allowed | not allowed | allowed | `65533:65533` | server=root_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_redhat` | `maglev (1234:1234)` | allowed | not allowed | allowed | `1234:1234` | server=root_squash,anon=redhat(65533:65533); client mapped to 1234:1234; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_redhat` | `postgres (1001:1001)` | allowed | not allowed | allowed | `1001:1001` | server=root_squash,anon=redhat(65533:65533); client mapped to 1001:1001; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `1002:1002` | server=root_squash,anon=redhat(65533:65533); client mapped to 1002:1002; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `1003:1003` | server=root_squash,anon=redhat(65533:65533); client mapped to 1003:1003; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_windows` | `root (0:0)` | allowed | not allowed | allowed | `65532:65532` | server=root_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_windows` | `maglev (1234:1234)` | allowed | not allowed | allowed | `1234:1234` | server=root_squash,anon=windows(65532:65532); client mapped to 1234:1234; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_windows` | `postgres (1001:1001)` | allowed | not allowed | allowed | `1001:1001` | server=root_squash,anon=windows(65532:65532); client mapped to 1001:1001; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_windows` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `1002:1002` | server=root_squash,anon=windows(65532:65532); client mapped to 1002:1002; access via other bits |
| `owner_root_perm_755_squash_root_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `1003:1003` | server=root_squash,anon=windows(65532:65532); client mapped to 1003:1003; access via other bits |
| `owner_root_perm_755_squash_no_squash` | `root (0:0)` | allowed | allowed | allowed | `0:0` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_root_perm_755_squash_no_squash` | `maglev (1234:1234)` | allowed | not allowed | allowed | `1234:1234` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_root_perm_755_squash_no_squash` | `postgres (1001:1001)` | allowed | not allowed | allowed | `1001:1001` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_root_perm_755_squash_no_squash` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `1002:1002` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_root_perm_755_squash_no_squash` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `1003:1003` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |

### owner=root, perm=644

| Export Directory | Client User (uid:gid) | Read | Write | Execute | Final Owner (uid:gid) | Comment |
|---|---|---|---|---|---|---|
| `owner_root_perm_644_squash_all_squash_anon_ubuntu` | `root (0:0)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_redhat` | `root (0:0)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_redhat` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_redhat` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_windows` | `root (0:0)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_windows` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_windows` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_windows` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_644_squash_all_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_ubuntu` | `root (0:0)` | allowed | not allowed | not allowed | `65534:65534` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1234:1234; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1001:1001; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1002:1002; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1003:1003; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_redhat` | `root (0:0)` | allowed | not allowed | not allowed | `65533:65533` | server=root_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_redhat` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=redhat(65533:65533); client mapped to 1234:1234; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_redhat` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=redhat(65533:65533); client mapped to 1001:1001; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=redhat(65533:65533); client mapped to 1002:1002; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=redhat(65533:65533); client mapped to 1003:1003; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_windows` | `root (0:0)` | allowed | not allowed | not allowed | `65532:65532` | server=root_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_windows` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=windows(65532:65532); client mapped to 1234:1234; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_windows` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=windows(65532:65532); client mapped to 1001:1001; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_windows` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=windows(65532:65532); client mapped to 1002:1002; access via other bits |
| `owner_root_perm_644_squash_root_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=windows(65532:65532); client mapped to 1003:1003; access via other bits |
| `owner_root_perm_644_squash_no_squash` | `root (0:0)` | allowed | allowed | not allowed | `0:0` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_root_perm_644_squash_no_squash` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_root_perm_644_squash_no_squash` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_root_perm_644_squash_no_squash` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_root_perm_644_squash_no_squash` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |

### owner=root, perm=600

| Export Directory | Client User (uid:gid) | Read | Write | Execute | Final Owner (uid:gid) | Comment |
|---|---|---|---|---|---|---|
| `owner_root_perm_600_squash_all_squash_anon_ubuntu` | `root (0:0)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_ubuntu` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_ubuntu` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_ubuntu` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_redhat` | `root (0:0)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_redhat` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_redhat` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_redhat` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_redhat` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_windows` | `root (0:0)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_windows` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_windows` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_windows` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_600_squash_all_squash_anon_windows` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_ubuntu` | `root (0:0)` | not allowed | not allowed | not allowed | `65534:65534` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_ubuntu` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1234:1234; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_ubuntu` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1001:1001; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_ubuntu` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1002:1002; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1003:1003; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_redhat` | `root (0:0)` | not allowed | not allowed | not allowed | `65533:65533` | server=root_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_redhat` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=redhat(65533:65533); client mapped to 1234:1234; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_redhat` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=redhat(65533:65533); client mapped to 1001:1001; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_redhat` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=redhat(65533:65533); client mapped to 1002:1002; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_redhat` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=redhat(65533:65533); client mapped to 1003:1003; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_windows` | `root (0:0)` | not allowed | not allowed | not allowed | `65532:65532` | server=root_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_windows` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=windows(65532:65532); client mapped to 1234:1234; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_windows` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=windows(65532:65532); client mapped to 1001:1001; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_windows` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=windows(65532:65532); client mapped to 1002:1002; access via other bits |
| `owner_root_perm_600_squash_root_squash_anon_windows` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=windows(65532:65532); client mapped to 1003:1003; access via other bits |
| `owner_root_perm_600_squash_no_squash` | `root (0:0)` | allowed | allowed | not allowed | `0:0` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_root_perm_600_squash_no_squash` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_root_perm_600_squash_no_squash` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_root_perm_600_squash_no_squash` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_root_perm_600_squash_no_squash` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |

### owner=root, perm=700

| Export Directory | Client User (uid:gid) | Read | Write | Execute | Final Owner (uid:gid) | Comment |
|---|---|---|---|---|---|---|
| `owner_root_perm_700_squash_all_squash_anon_ubuntu` | `root (0:0)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_ubuntu` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_ubuntu` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_ubuntu` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_redhat` | `root (0:0)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_redhat` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_redhat` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_redhat` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_redhat` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_windows` | `root (0:0)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_windows` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_windows` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_windows` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_700_squash_all_squash_anon_windows` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_ubuntu` | `root (0:0)` | not allowed | not allowed | not allowed | `65534:65534` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_ubuntu` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1234:1234; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_ubuntu` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1001:1001; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_ubuntu` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1002:1002; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1003:1003; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_redhat` | `root (0:0)` | not allowed | not allowed | not allowed | `65533:65533` | server=root_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_redhat` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=redhat(65533:65533); client mapped to 1234:1234; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_redhat` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=redhat(65533:65533); client mapped to 1001:1001; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_redhat` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=redhat(65533:65533); client mapped to 1002:1002; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_redhat` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=redhat(65533:65533); client mapped to 1003:1003; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_windows` | `root (0:0)` | not allowed | not allowed | not allowed | `65532:65532` | server=root_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_windows` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=windows(65532:65532); client mapped to 1234:1234; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_windows` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=windows(65532:65532); client mapped to 1001:1001; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_windows` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=windows(65532:65532); client mapped to 1002:1002; access via other bits |
| `owner_root_perm_700_squash_root_squash_anon_windows` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=windows(65532:65532); client mapped to 1003:1003; access via other bits |
| `owner_root_perm_700_squash_no_squash` | `root (0:0)` | allowed | allowed | allowed | `0:0` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_root_perm_700_squash_no_squash` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_root_perm_700_squash_no_squash` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_root_perm_700_squash_no_squash` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_root_perm_700_squash_no_squash` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |

### owner=root, perm=444

| Export Directory | Client User (uid:gid) | Read | Write | Execute | Final Owner (uid:gid) | Comment |
|---|---|---|---|---|---|---|
| `owner_root_perm_444_squash_all_squash_anon_ubuntu` | `root (0:0)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_redhat` | `root (0:0)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_redhat` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_redhat` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_windows` | `root (0:0)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_windows` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_windows` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_windows` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_root_perm_444_squash_all_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_ubuntu` | `root (0:0)` | allowed | not allowed | not allowed | `65534:65534` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1234:1234; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1001:1001; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1002:1002; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1003:1003; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_redhat` | `root (0:0)` | allowed | not allowed | not allowed | `65533:65533` | server=root_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_redhat` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=redhat(65533:65533); client mapped to 1234:1234; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_redhat` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=redhat(65533:65533); client mapped to 1001:1001; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=redhat(65533:65533); client mapped to 1002:1002; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=redhat(65533:65533); client mapped to 1003:1003; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_windows` | `root (0:0)` | allowed | not allowed | not allowed | `65532:65532` | server=root_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_windows` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=windows(65532:65532); client mapped to 1234:1234; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_windows` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=windows(65532:65532); client mapped to 1001:1001; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_windows` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=windows(65532:65532); client mapped to 1002:1002; access via owner bits |
| `owner_root_perm_444_squash_root_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=windows(65532:65532); client mapped to 1003:1003; access via owner bits |
| `owner_root_perm_444_squash_no_squash` | `root (0:0)` | allowed | not allowed | not allowed | `0:0` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_root_perm_444_squash_no_squash` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_root_perm_444_squash_no_squash` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_root_perm_444_squash_no_squash` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_root_perm_444_squash_no_squash` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |

### owner=ccexportuser, perm=777

| Export Directory | Client User (uid:gid) | Read | Write | Execute | Final Owner (uid:gid) | Comment |
|---|---|---|---|---|---|---|
| `owner_ccexportuser_perm_777_squash_all_squash_anon_ubuntu` | `root (0:0)` | allowed | allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_redhat` | `root (0:0)` | allowed | allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_redhat` | `maglev (1234:1234)` | allowed | allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_redhat` | `postgres (1001:1001)` | allowed | allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_windows` | `root (0:0)` | allowed | allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_windows` | `maglev (1234:1234)` | allowed | allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_windows` | `postgres (1001:1001)` | allowed | allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_windows` | `mongodb (1002:1002)` | allowed | allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_ccexportuser_perm_777_squash_all_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_ubuntu` | `root (0:0)` | allowed | allowed | allowed | `65534:65534` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | allowed | allowed | `1234:1234` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1234:1234; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | allowed | allowed | `1001:1001` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1001:1001; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | allowed | allowed | `1002:1002` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1002:1002; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `1003:1003` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1003:1003; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_redhat` | `root (0:0)` | allowed | allowed | allowed | `65533:65533` | server=root_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_redhat` | `maglev (1234:1234)` | allowed | allowed | allowed | `1234:1234` | server=root_squash,anon=redhat(65533:65533); client mapped to 1234:1234; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_redhat` | `postgres (1001:1001)` | allowed | allowed | allowed | `1001:1001` | server=root_squash,anon=redhat(65533:65533); client mapped to 1001:1001; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | allowed | allowed | `1002:1002` | server=root_squash,anon=redhat(65533:65533); client mapped to 1002:1002; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `1003:1003` | server=root_squash,anon=redhat(65533:65533); client mapped to 1003:1003; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_windows` | `root (0:0)` | allowed | allowed | allowed | `65532:65532` | server=root_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_windows` | `maglev (1234:1234)` | allowed | allowed | allowed | `1234:1234` | server=root_squash,anon=windows(65532:65532); client mapped to 1234:1234; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_windows` | `postgres (1001:1001)` | allowed | allowed | allowed | `1001:1001` | server=root_squash,anon=windows(65532:65532); client mapped to 1001:1001; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_windows` | `mongodb (1002:1002)` | allowed | allowed | allowed | `1002:1002` | server=root_squash,anon=windows(65532:65532); client mapped to 1002:1002; access via owner bits |
| `owner_ccexportuser_perm_777_squash_root_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `1003:1003` | server=root_squash,anon=windows(65532:65532); client mapped to 1003:1003; access via owner bits |
| `owner_ccexportuser_perm_777_squash_no_squash` | `root (0:0)` | allowed | allowed | allowed | `0:0` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_ccexportuser_perm_777_squash_no_squash` | `maglev (1234:1234)` | allowed | allowed | allowed | `1234:1234` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_ccexportuser_perm_777_squash_no_squash` | `postgres (1001:1001)` | allowed | allowed | allowed | `1001:1001` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_ccexportuser_perm_777_squash_no_squash` | `mongodb (1002:1002)` | allowed | allowed | allowed | `1002:1002` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_ccexportuser_perm_777_squash_no_squash` | `elasticsearch (1003:1003)` | allowed | allowed | allowed | `1003:1003` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |

### owner=ccexportuser, perm=755

| Export Directory | Client User (uid:gid) | Read | Write | Execute | Final Owner (uid:gid) | Comment |
|---|---|---|---|---|---|---|
| `owner_ccexportuser_perm_755_squash_all_squash_anon_ubuntu` | `root (0:0)` | allowed | not allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | not allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | not allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_redhat` | `root (0:0)` | allowed | not allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_redhat` | `maglev (1234:1234)` | allowed | not allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_redhat` | `postgres (1001:1001)` | allowed | not allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_windows` | `root (0:0)` | allowed | not allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_windows` | `maglev (1234:1234)` | allowed | not allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_windows` | `postgres (1001:1001)` | allowed | not allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_windows` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_755_squash_all_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_ubuntu` | `root (0:0)` | allowed | not allowed | allowed | `65534:65534` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | not allowed | allowed | `1234:1234` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1234:1234; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | not allowed | allowed | `1001:1001` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1001:1001; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `1002:1002` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1002:1002; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `1003:1003` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1003:1003; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_redhat` | `root (0:0)` | allowed | not allowed | allowed | `65533:65533` | server=root_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_redhat` | `maglev (1234:1234)` | allowed | not allowed | allowed | `1234:1234` | server=root_squash,anon=redhat(65533:65533); client mapped to 1234:1234; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_redhat` | `postgres (1001:1001)` | allowed | not allowed | allowed | `1001:1001` | server=root_squash,anon=redhat(65533:65533); client mapped to 1001:1001; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `1002:1002` | server=root_squash,anon=redhat(65533:65533); client mapped to 1002:1002; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `1003:1003` | server=root_squash,anon=redhat(65533:65533); client mapped to 1003:1003; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_windows` | `root (0:0)` | allowed | not allowed | allowed | `65532:65532` | server=root_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_windows` | `maglev (1234:1234)` | allowed | not allowed | allowed | `1234:1234` | server=root_squash,anon=windows(65532:65532); client mapped to 1234:1234; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_windows` | `postgres (1001:1001)` | allowed | not allowed | allowed | `1001:1001` | server=root_squash,anon=windows(65532:65532); client mapped to 1001:1001; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_windows` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `1002:1002` | server=root_squash,anon=windows(65532:65532); client mapped to 1002:1002; access via other bits |
| `owner_ccexportuser_perm_755_squash_root_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `1003:1003` | server=root_squash,anon=windows(65532:65532); client mapped to 1003:1003; access via other bits |
| `owner_ccexportuser_perm_755_squash_no_squash` | `root (0:0)` | allowed | not allowed | allowed | `0:0` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_755_squash_no_squash` | `maglev (1234:1234)` | allowed | not allowed | allowed | `1234:1234` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_755_squash_no_squash` | `postgres (1001:1001)` | allowed | not allowed | allowed | `1001:1001` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_755_squash_no_squash` | `mongodb (1002:1002)` | allowed | not allowed | allowed | `1002:1002` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_755_squash_no_squash` | `elasticsearch (1003:1003)` | allowed | not allowed | allowed | `1003:1003` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |

### owner=ccexportuser, perm=644

| Export Directory | Client User (uid:gid) | Read | Write | Execute | Final Owner (uid:gid) | Comment |
|---|---|---|---|---|---|---|
| `owner_ccexportuser_perm_644_squash_all_squash_anon_ubuntu` | `root (0:0)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_redhat` | `root (0:0)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_redhat` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_redhat` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_windows` | `root (0:0)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_windows` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_windows` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_windows` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_644_squash_all_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_ubuntu` | `root (0:0)` | allowed | not allowed | not allowed | `65534:65534` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1234:1234; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1001:1001; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1002:1002; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1003:1003; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_redhat` | `root (0:0)` | allowed | not allowed | not allowed | `65533:65533` | server=root_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_redhat` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=redhat(65533:65533); client mapped to 1234:1234; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_redhat` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=redhat(65533:65533); client mapped to 1001:1001; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=redhat(65533:65533); client mapped to 1002:1002; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=redhat(65533:65533); client mapped to 1003:1003; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_windows` | `root (0:0)` | allowed | not allowed | not allowed | `65532:65532` | server=root_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_windows` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=windows(65532:65532); client mapped to 1234:1234; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_windows` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=windows(65532:65532); client mapped to 1001:1001; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_windows` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=windows(65532:65532); client mapped to 1002:1002; access via other bits |
| `owner_ccexportuser_perm_644_squash_root_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=windows(65532:65532); client mapped to 1003:1003; access via other bits |
| `owner_ccexportuser_perm_644_squash_no_squash` | `root (0:0)` | allowed | not allowed | not allowed | `0:0` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_644_squash_no_squash` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_644_squash_no_squash` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_644_squash_no_squash` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_644_squash_no_squash` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |

### owner=ccexportuser, perm=600

| Export Directory | Client User (uid:gid) | Read | Write | Execute | Final Owner (uid:gid) | Comment |
|---|---|---|---|---|---|---|
| `owner_ccexportuser_perm_600_squash_all_squash_anon_ubuntu` | `root (0:0)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_ubuntu` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_ubuntu` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_ubuntu` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_redhat` | `root (0:0)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_redhat` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_redhat` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_redhat` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_redhat` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_windows` | `root (0:0)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_windows` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_windows` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_windows` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_600_squash_all_squash_anon_windows` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_ubuntu` | `root (0:0)` | not allowed | not allowed | not allowed | `65534:65534` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_ubuntu` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1234:1234; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_ubuntu` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1001:1001; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_ubuntu` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1002:1002; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1003:1003; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_redhat` | `root (0:0)` | not allowed | not allowed | not allowed | `65533:65533` | server=root_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_redhat` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=redhat(65533:65533); client mapped to 1234:1234; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_redhat` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=redhat(65533:65533); client mapped to 1001:1001; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_redhat` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=redhat(65533:65533); client mapped to 1002:1002; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_redhat` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=redhat(65533:65533); client mapped to 1003:1003; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_windows` | `root (0:0)` | not allowed | not allowed | not allowed | `65532:65532` | server=root_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_windows` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=windows(65532:65532); client mapped to 1234:1234; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_windows` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=windows(65532:65532); client mapped to 1001:1001; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_windows` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=windows(65532:65532); client mapped to 1002:1002; access via other bits |
| `owner_ccexportuser_perm_600_squash_root_squash_anon_windows` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=windows(65532:65532); client mapped to 1003:1003; access via other bits |
| `owner_ccexportuser_perm_600_squash_no_squash` | `root (0:0)` | not allowed | not allowed | not allowed | `0:0` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_600_squash_no_squash` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_600_squash_no_squash` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_600_squash_no_squash` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_600_squash_no_squash` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |

### owner=ccexportuser, perm=700

| Export Directory | Client User (uid:gid) | Read | Write | Execute | Final Owner (uid:gid) | Comment |
|---|---|---|---|---|---|---|
| `owner_ccexportuser_perm_700_squash_all_squash_anon_ubuntu` | `root (0:0)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_ubuntu` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_ubuntu` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_ubuntu` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_redhat` | `root (0:0)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_redhat` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_redhat` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_redhat` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_redhat` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_windows` | `root (0:0)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_windows` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_windows` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_windows` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_700_squash_all_squash_anon_windows` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_ubuntu` | `root (0:0)` | not allowed | not allowed | not allowed | `65534:65534` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_ubuntu` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1234:1234; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_ubuntu` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1001:1001; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_ubuntu` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1002:1002; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1003:1003; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_redhat` | `root (0:0)` | not allowed | not allowed | not allowed | `65533:65533` | server=root_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_redhat` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=redhat(65533:65533); client mapped to 1234:1234; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_redhat` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=redhat(65533:65533); client mapped to 1001:1001; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_redhat` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=redhat(65533:65533); client mapped to 1002:1002; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_redhat` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=redhat(65533:65533); client mapped to 1003:1003; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_windows` | `root (0:0)` | not allowed | not allowed | not allowed | `65532:65532` | server=root_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_windows` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=windows(65532:65532); client mapped to 1234:1234; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_windows` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=windows(65532:65532); client mapped to 1001:1001; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_windows` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=windows(65532:65532); client mapped to 1002:1002; access via other bits |
| `owner_ccexportuser_perm_700_squash_root_squash_anon_windows` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=windows(65532:65532); client mapped to 1003:1003; access via other bits |
| `owner_ccexportuser_perm_700_squash_no_squash` | `root (0:0)` | not allowed | not allowed | not allowed | `0:0` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_700_squash_no_squash` | `maglev (1234:1234)` | not allowed | not allowed | not allowed | `1234:1234` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_700_squash_no_squash` | `postgres (1001:1001)` | not allowed | not allowed | not allowed | `1001:1001` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_700_squash_no_squash` | `mongodb (1002:1002)` | not allowed | not allowed | not allowed | `1002:1002` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |
| `owner_ccexportuser_perm_700_squash_no_squash` | `elasticsearch (1003:1003)` | not allowed | not allowed | not allowed | `1003:1003` | server=no_root_squash,no anon; client uid/gid preserved; access via other bits |

### owner=ccexportuser, perm=444

| Export Directory | Client User (uid:gid) | Read | Write | Execute | Final Owner (uid:gid) | Comment |
|---|---|---|---|---|---|---|
| `owner_ccexportuser_perm_444_squash_all_squash_anon_ubuntu` | `root (0:0)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `65534:65534` | server=all_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_redhat` | `root (0:0)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_redhat` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_redhat` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `65533:65533` | server=all_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_windows` | `root (0:0)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_windows` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_windows` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_windows` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_ccexportuser_perm_444_squash_all_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `65532:65532` | server=all_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_ubuntu` | `root (0:0)` | allowed | not allowed | not allowed | `65534:65534` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 65534:65534; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_ubuntu` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1234:1234; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_ubuntu` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1001:1001; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_ubuntu` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1002:1002; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_ubuntu` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=ubuntu(65534:65534); client mapped to 1003:1003; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_redhat` | `root (0:0)` | allowed | not allowed | not allowed | `65533:65533` | server=root_squash,anon=redhat(65533:65533); client mapped to 65533:65533; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_redhat` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=redhat(65533:65533); client mapped to 1234:1234; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_redhat` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=redhat(65533:65533); client mapped to 1001:1001; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_redhat` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=redhat(65533:65533); client mapped to 1002:1002; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_redhat` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=redhat(65533:65533); client mapped to 1003:1003; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_windows` | `root (0:0)` | allowed | not allowed | not allowed | `65532:65532` | server=root_squash,anon=windows(65532:65532); client mapped to 65532:65532; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_windows` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=root_squash,anon=windows(65532:65532); client mapped to 1234:1234; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_windows` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=root_squash,anon=windows(65532:65532); client mapped to 1001:1001; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_windows` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=root_squash,anon=windows(65532:65532); client mapped to 1002:1002; access via owner bits |
| `owner_ccexportuser_perm_444_squash_root_squash_anon_windows` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=root_squash,anon=windows(65532:65532); client mapped to 1003:1003; access via owner bits |
| `owner_ccexportuser_perm_444_squash_no_squash` | `root (0:0)` | allowed | not allowed | not allowed | `0:0` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_ccexportuser_perm_444_squash_no_squash` | `maglev (1234:1234)` | allowed | not allowed | not allowed | `1234:1234` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_ccexportuser_perm_444_squash_no_squash` | `postgres (1001:1001)` | allowed | not allowed | not allowed | `1001:1001` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_ccexportuser_perm_444_squash_no_squash` | `mongodb (1002:1002)` | allowed | not allowed | not allowed | `1002:1002` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
| `owner_ccexportuser_perm_444_squash_no_squash` | `elasticsearch (1003:1003)` | allowed | not allowed | not allowed | `1003:1003` | server=no_root_squash,no anon; client uid/gid preserved; access via owner bits |
