# NFS Export Behavior Lab

This repository contains reproducible NFS export behavior labs organized by protocol/version.

## Repository Structure

- `docker-compose.yml`: active compose topology for the current lab setup.
- `nfsv4/`: NFSv4-specific server/client implementation and documentation.

Version-specific documentation:
- NFSv4: `nfsv4/README.md`

## Quick Start

From repository root:

```bash
docker compose up --build -d
```

Validate from the client container:

```bash
docker compose exec -T nfs-client \
  python3 /usr/local/bin/validate_readme_matrix.py \
  --readme /workspace/nfsv4/README.md \
  --mount-base /mnt/nfs
```

Stop and clean up:

```bash
docker compose down
```

## Notes

- Keep protocol/version-specific behavior, assumptions, and matrices in versioned directories (for example `nfsv4/`).
- Keep the root README generic so additional versions (for example `nfsv3/`, `nfsv41/`) can be added cleanly.
