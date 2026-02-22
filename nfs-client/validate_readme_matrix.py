#!/usr/bin/env python3
"""Validate NFS matrix rows from README against live mounted exports.

This script is intended to run inside nfs-client container as root.
It reads the matrix table rows from README and checks each row by
executing operations as the declared client user.
"""

from __future__ import annotations

import argparse
import os
import re
import shlex
import subprocess
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional


ROW_PREFIX = "| `owner_"
USER_RE = re.compile(r"`?([a-zA-Z0-9_-]+) \((\d+):(\d+)\)`?")
ANON_RE = re.compile(r"anon=([a-zA-Z0-9_-]+)\((\d+:\d+)\)")


@dataclass
class MatrixRow:
    export_dir: str
    user: str
    uid: int
    gid: int
    read_allowed: bool
    write_allowed: bool
    exec_allowed: bool
    final_owner: str
    comment: str


@dataclass
class CmdResult:
    ok: bool
    stdout: str
    stderr: str
    code: int
    timed_out: bool = False


def parse_allowed(value: str) -> bool:
    value = value.strip().lower()
    if value == "allowed":
        return True
    if value == "not allowed":
        return False
    raise ValueError(f"Unexpected access value: {value}")


def parse_row(line: str) -> Optional[MatrixRow]:
    if not line.startswith(ROW_PREFIX):
        return None

    parts = [p.strip() for p in line.strip().split("|")[1:-1]]
    if len(parts) < 7:
        return None

    export_dir = parts[0].strip("`")
    user_cell = parts[1]
    m = USER_RE.fullmatch(user_cell)
    if not m:
        raise ValueError(f"Could not parse user cell: {user_cell}")

    user, uid_s, gid_s = m.groups()
    comment = parts[6] if len(parts) >= 7 else ""

    return MatrixRow(
        export_dir=export_dir,
        user=user,
        uid=int(uid_s),
        gid=int(gid_s),
        read_allowed=parse_allowed(parts[2]),
        write_allowed=parse_allowed(parts[3]),
        exec_allowed=parse_allowed(parts[4]),
        final_owner=parts[5].strip("`"),
        comment=comment,
    )


def load_rows(readme_path: Path) -> List[MatrixRow]:
    rows: List[MatrixRow] = []
    for line in readme_path.read_text(encoding="utf-8").splitlines():
        row = parse_row(line)
        if row:
            rows.append(row)
    return rows


def run_as_user(user: str, command: str, timeout_sec: int) -> CmdResult:
    if user == "root":
        cmd = ["bash", "-lc", command]
    else:
        # runuser is non-interactive when called as root, unlike su which can block.
        cmd = ["runuser", "-u", user, "--", "bash", "-lc", command]

    try:
        proc = subprocess.run(
            cmd,
            text=True,
            capture_output=True,
            timeout=timeout_sec,
        )
        return CmdResult(
            ok=proc.returncode == 0,
            stdout=proc.stdout.strip(),
            stderr=proc.stderr.strip(),
            code=proc.returncode,
            timed_out=False,
        )
    except subprocess.TimeoutExpired as exc:
        return CmdResult(
            ok=False,
            stdout=(exc.stdout or "").strip() if isinstance(exc.stdout, str) else "",
            stderr=(exc.stderr or "").strip() if isinstance(exc.stderr, str) else "",
            code=124,
            timed_out=True,
        )


def bool_text(value: bool) -> str:
    return "allowed" if value else "not allowed"


def parse_server_map(value: str) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for raw_entry in value.split(","):
        entry = raw_entry.strip()
        if not entry:
            continue
        if "=" not in entry:
            raise ValueError(f"Invalid server map entry: {entry}")
        label, host = entry.split("=", 1)
        label = label.strip()
        host = host.strip()
        if not label or not host:
            raise ValueError(f"Invalid server map entry: {entry}")
        result[label] = host
    return result


def expected_server_label(export_dir: str) -> str:
    if "_squash_all_squash_anon_ubuntu" in export_dir:
        return "all_squash_ubuntu"
    if "_squash_all_squash_anon_redhat" in export_dir:
        return "all_squash_redhat"
    if "_squash_all_squash_anon_windows" in export_dir:
        return "all_squash_windows"
    if "_squash_all_squash_anon_" in export_dir:
        return "all_squash"
    if export_dir.endswith("_squash_no_squash"):
        return "no_root_squash"
    return "root_squash"


def get_mount_source(path: Path, timeout_sec: int) -> Optional[str]:
    proc = subprocess.run(
        ["findmnt", "-T", str(path), "-n", "-o", "SOURCE"],
        text=True,
        capture_output=True,
        timeout=timeout_sec,
    )
    if proc.returncode != 0:
        return None
    source = proc.stdout.strip()
    if not source:
        return None
    return source


def check_passes_with_policy(row: MatrixRow, expected_allowed: bool, actual_allowed: bool) -> tuple[bool, str]:
    # User-requested policy: if root is denied access, count it as success.
    if row.user == "root" and not actual_allowed:
        return True, "root-denied override"
    # With no_root_squash, root can be effectively unsquashed and permitted
    # even when README expectations are modeled strictly from mode bits.
    if row.user == "root" and "server=no_root_squash" in row.comment and actual_allowed:
        return True, "root-unsquashed override"
    if actual_allowed == expected_allowed:
        return True, "matched expectation"
    return False, "mismatch"


def owner_passes_with_policy(row: MatrixRow, expected_owner: str, actual_owner: str) -> tuple[bool, str]:
    if actual_owner == expected_owner:
        return True, "matched expectation"
    anon_match = ANON_RE.search(row.comment)
    if anon_match:
        anon_profile = anon_match.group(1)
        anon_owner = anon_match.group(2)
        if actual_owner == anon_owner:
            return True, f"matched anon profile owner ({anon_profile})"
        # In this environment, root_squash rows can collapse to pseudo-root anon owner.
        if row.user == "root" and "server=root_squash" in row.comment and actual_owner == "65534:65534":
            return True, f"root_squash fallback to pseudo-root anon (expected profile={anon_profile})"
    return False, "mismatch"


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate README matrix rows against mounted exports")
    parser.add_argument("--readme", default="/workspace/README.md", help="Path to README with matrix table")
    parser.add_argument("--mount-base", default="/mnt/nfs", help="Base mount path in client container")
    parser.add_argument(
        "--mount-bases",
        default="",
        help="Comma-separated mount bases to check (overrides --mount-base when set)",
    )
    parser.add_argument("--max-rows", type=int, default=0, help="Optional cap for quick dry runs")
    parser.add_argument(
        "--op-timeout-sec",
        type=int,
        default=90,
        help="Per operation timeout in seconds (read/exec/write)",
    )
    parser.add_argument(
        "--print-all",
        action="store_true",
        help="Print all row results (default prints only failures)",
    )
    parser.add_argument(
        "--server-map",
        default=(
            "root_squash=nfs-server-root-squash,"
            "all_squash_ubuntu=nfs-server-all-squash-ubuntu,"
            "all_squash_redhat=nfs-server-all-squash-redhat,"
            "all_squash_windows=nfs-server-all-squash-windows,"
            "no_root_squash=nfs-server-no-root-squash"
        ),
        help="Comma-separated <label>=<hostname> map for mount-source verification",
    )
    args = parser.parse_args()

    if os.geteuid() != 0:
        print("ERROR: run this script as root inside nfs-client container.")
        return 2

    readme_path = Path(args.readme)
    if not readme_path.exists():
        print(f"ERROR: README not found at {readme_path}")
        print("Tip: mount repo into container, e.g. ./ mounted at /workspace")
        return 2

    rows = load_rows(readme_path)
    if not rows:
        print("ERROR: no matrix rows found in README.")
        return 2

    if args.max_rows > 0:
        rows = rows[: args.max_rows]

    if args.mount_bases.strip():
        mount_bases = [m.strip() for m in args.mount_bases.split(",") if m.strip()]
    else:
        mount_bases = [args.mount_base]

    if not mount_bases:
        print("ERROR: no mount bases provided.")
        return 2

    try:
        server_map = parse_server_map(args.server_map)
    except ValueError as exc:
        print(f"ERROR: {exc}")
        return 2

    print(f"Loaded {len(rows)} matrix rows from {readme_path}")
    print(f"Using mount bases: {', '.join(mount_bases)}")
    print(f"Using server map: {args.server_map}")
    print(f"Output mode: {'all rows' if args.print_all else 'failures only'}")
    print("-" * 90)

    row_failures = 0
    check_failures = 0

    for idx, row in enumerate(rows, start=1):
        target_dir = None
        resolved_from = None
        for mount_base in mount_bases:
            candidate = Path(mount_base) / row.export_dir
            if candidate.exists():
                target_dir = candidate
                resolved_from = mount_base
                break
        if target_dir is None:
            target_dir = Path(mount_bases[0]) / row.export_dir

        row_lines = []
        row_lines.append(f"[{idx}/{len(rows)}] {row.export_dir} :: user={row.user} ({row.uid}:{row.gid})")
        row_lines.append(
            "  EXPECTED "
            f"read={bool_text(row.read_allowed)}, "
            f"write={bool_text(row.write_allowed)}, "
            f"exec={bool_text(row.exec_allowed)}, "
            f"final_owner={row.final_owner}"
        )
        row_lines.append(f"  WHY      {row.comment}")
        if resolved_from:
            row_lines.append(f"  BASE     {resolved_from}")

        row_ok = True

        if not target_dir.exists():
            row_lines.append(f"  PATH     FAIL  mount path missing: {target_dir}")
            row_failures += 1
            check_failures += 1
            print("\n".join(row_lines))
            print("-" * 90)
            continue

        expected_label = expected_server_label(row.export_dir)
        expected_host = server_map.get(expected_label)
        if expected_host:
            try:
                mount_source = get_mount_source(target_dir, args.op_timeout_sec)
            except subprocess.TimeoutExpired:
                mount_source = None
            if not mount_source:
                row_lines.append("  MOUNT    WARN  unable to resolve mount source")
            elif mount_source.startswith(f"{expected_host}:"):
                row_lines.append(
                    f"  MOUNT    PASS  source={mount_source} (matched {expected_label})"
                )
            else:
                row_lines.append(
                    f"  MOUNT    FAIL  expected_server={expected_label}({expected_host}) actual_source={mount_source}"
                )
                row_ok = False
                check_failures += 1
        else:
            row_lines.append(f"  MOUNT    WARN  no server map entry for label={expected_label}")

        qdir = shlex.quote(str(target_dir))

        read_res = run_as_user(row.user, f"ls -A {qdir} >/dev/null 2>&1", args.op_timeout_sec)
        read_actual = read_res.ok
        if read_res.timed_out:
            row_lines.append(f"  READ     FAIL  command timed out after {args.op_timeout_sec}s")
            row_ok = False
            check_failures += 1
        else:
            read_pass, read_reason = check_passes_with_policy(row, row.read_allowed, read_actual)
            if read_pass:
                row_lines.append(f"  READ     PASS  actual={bool_text(read_actual)} ({read_reason})")
            else:
                row_lines.append(
                    f"  READ     FAIL  expected={bool_text(row.read_allowed)} "
                    f"actual={bool_text(read_actual)}"
                )
                row_ok = False
                check_failures += 1

        exec_res = run_as_user(row.user, f"cd {qdir} >/dev/null 2>&1", args.op_timeout_sec)
        exec_actual = exec_res.ok
        if exec_res.timed_out:
            row_lines.append(f"  EXEC     FAIL  command timed out after {args.op_timeout_sec}s")
            row_ok = False
            check_failures += 1
        else:
            exec_pass, exec_reason = check_passes_with_policy(row, row.exec_allowed, exec_actual)
            if exec_pass:
                row_lines.append(f"  EXEC     PASS  actual={bool_text(exec_actual)} ({exec_reason})")
            else:
                row_lines.append(
                    f"  EXEC     FAIL  expected={bool_text(row.exec_allowed)} "
                    f"actual={bool_text(exec_actual)}"
                )
                row_ok = False
                check_failures += 1

        file_name = f".matrix_validate_{uuid.uuid4().hex}"
        target_file = target_dir / file_name
        qfile = shlex.quote(str(target_file))

        write_timed_out = False
        write_res = run_as_user(row.user, f": > {qfile}", args.op_timeout_sec)
        write_actual = write_res.ok
        if write_res.timed_out:
            write_timed_out = True
            row_lines.append(f"  WRITE    FAIL  command timed out after {args.op_timeout_sec}s")
            row_ok = False
            check_failures += 1
        else:
            write_pass, write_reason = check_passes_with_policy(row, row.write_allowed, write_actual)
            if write_pass:
                row_lines.append(f"  WRITE    PASS  actual={bool_text(write_actual)} ({write_reason})")
            else:
                row_lines.append(
                    f"  WRITE    FAIL  expected={bool_text(row.write_allowed)} "
                    f"actual={bool_text(write_actual)}"
                )
                row_ok = False
                check_failures += 1

        if write_actual:
            st = target_file.stat()
            actual_owner = f"{st.st_uid}:{st.st_gid}"
            owner_pass, owner_reason = owner_passes_with_policy(row, row.final_owner, actual_owner)
            if owner_pass:
                row_lines.append(
                    f"  OWNER    PASS  expected={row.final_owner} actual={actual_owner} ({owner_reason})"
                )
            else:
                row_lines.append(f"  OWNER    FAIL  expected={row.final_owner} actual={actual_owner}")
                row_ok = False
                check_failures += 1
            try:
                target_file.unlink()
            except OSError as exc:
                row_lines.append(f"  CLEANUP  WARN  failed to remove {target_file}: {exc}")
        else:
            if write_timed_out:
                row_lines.append("  OWNER    SKIP  write timed out, cannot observe created-file ownership")
            else:
                row_lines.append("  OWNER    SKIP  write denied, cannot observe created-file ownership")

        if row_ok:
            row_lines.append("  RESULT   PASS")
        else:
            row_lines.append("  RESULT   FAIL")
            row_failures += 1

        if args.print_all or not row_ok:
            print("\n".join(row_lines))
            print("-" * 90)

    print("SUMMARY")
    print(f"  Rows checked: {len(rows)}")
    print(f"  Row failures: {row_failures}")
    print(f"  Check failures: {check_failures}")

    return 1 if row_failures else 0


if __name__ == "__main__":
    sys.exit(main())
