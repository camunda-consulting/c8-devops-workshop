# Variant: incremental restore and disaster recovery (Camunda 8.9+)

This is **not** the standard Lab 3 procedure. Start with [`Instructions.md`](./Instructions.md).

Differences to the standard procedure (`../8.9/`):

| | Standard | This variant |
|---|---|---|
| Setup | One Camunda + one ES, everything deleted and rebuilt in place | Two ES clusters (`es-main`, `es-dr`) sharing one MinIO repository; only the main region is destroyed |
| ES restore | Delete all indices, restore everything | A warm `es-dr` is restored from backup #1 while production runs; after the disaster backup #2 is restored on top (close, then restore) so only changed segments transfer |
| Repository on restore target | writable | `readonly: true` (writable hides snapshots written later by the other cluster) |
| Zeebe restore | `helm upgrade` with restore values after deleting Zeebe PVCs | Fresh `helm install` with `restore/camunda-values-failover.yaml` (points to `es-dr`) plus `restore/camunda-zeebe-restore-values.yaml` |
| Missing here | | `find-backup` job, delete-all-indices job, `restore-backup.sh`, screenshots, Keycloak/OIDC setup |
