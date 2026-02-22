# NFS Export Behavior Lab

This repository contains reproducible NFS export behavior labs organized by protocol/version.

## Repository Structure

- `docker-compose.yml`: active compose topology for the current lab setup (currently wired to `nfsv3/`).
- `nfsv3/`: NFSv3-specific server/client implementation and documentation.
- `nfsv4/`: NFSv4-specific server/client implementation and documentation.

Version-specific documentation:
- NFSv3: `nfsv3/README.md`
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
  --readme /workspace/nfsv3/README.md \
  --mount-base /mnt/nfs
```

Stop and clean up:

```bash
docker compose down
```

## Version Notes

- NFSv3 setup details, assumptions, and matrix: `nfsv3/README.md`
- NFSv4 setup details, assumptions, and matrix: `nfsv4/README.md`
- Current `docker-compose.yml` targets the NFSv3 implementation paths.
- Both NFSv3 and NFSv4 lab images are based on Ubuntu 18.04.

## Validate By Version

NFSv3 matrix validation:

```bash
docker compose exec -T nfs-client \
  python3 /usr/local/bin/validate_readme_matrix.py \
  --readme /workspace/nfsv3/README.md \
  --mount-base /mnt/nfs
```

NFSv4 matrix validation (when running an NFSv4-targeted stack):

```bash
docker compose exec -T nfs-client \
  python3 /usr/local/bin/validate_readme_matrix.py \
  --readme /workspace/nfsv4/README.md \
  --mount-base /mnt/nfs
```

## Notes

- Keep protocol/version-specific behavior, assumptions, and matrices in versioned directories (for example `nfsv3/`).
- Keep the root README generic so additional versions (for example `nfsv41/`) can be added cleanly.
