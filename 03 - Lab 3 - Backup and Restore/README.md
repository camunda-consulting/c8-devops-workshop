# Lab 3 – Backup and Restore

The instructions and manifests in this lab depend on the Camunda minor version, so each version lives in its own **self-contained folder**. Alternative scenarios live under `variants/`.

## Standard procedure (backup, delete everything, full restore)

| Camunda version | Folder | Status |
|---|---|---|
| 8.9 | [`8.9/`](./8.9/Instructions.md) | **not yet tested end to end**, see [CHANGES.md](./CHANGES.md) |
| 8.8 | [`8.8/`](./8.8/Instructions.md) | tested |
| 8.7 | [`8.7/`](./8.7/Instructions.md) | legacy, for customers not yet on 8.8; content as it was on `main` before the restructure |

## Variants

| Variant | Folder | Works with | What is different |
|---|---|---|---|
| Incremental restore / disaster recovery | [`variants/incremental-restore-dr/`](./variants/incremental-restore-dr/Instructions.md) | 8.9+ | Two ES clusters; a warm DR cluster is restored incrementally, Zeebe is restored fully |

Open the `Instructions.md` of the folder you need and run all commands from inside that folder (paths are relative to it). What changed between versions and why: [CHANGES.md](./CHANGES.md).

## Adding a new Camunda version

1. `cp -r <latest>/ <new>/` (for example `cp -r 8.9 8.10`) and commit it on its own, so the follow-up commits show only the real upgrade changes.
2. Adapt values, manifests and `Instructions.md`, and test the lab end to end.
3. Add a section to [CHANGES.md](./CHANGES.md) and a row to the table above.
4. When a version is retired, tag it (`lab3-<version>-final`) and remove its folder.
