# Monorepo Migration Notes

The parent directory is intended to become the single git repository for:

- `IMApp`
- `IMClientKit`
- `IMServer`

At the time of migration, `IMApp` and `IMServer` are still independent git repositories with their own `.git` directories. To avoid accidental history loss, do not delete those directories until their history has either been backed up or intentionally flattened.

## Recommended Safe Conversion

1. Commit or intentionally stash all current changes inside `IMApp` and `IMServer`.
2. Create backup bundles:

```sh
mkdir -p monorepo-backups
git -C IMApp bundle create ../monorepo-backups/IMApp-pre-monorepo.bundle --all
git -C IMServer bundle create ../monorepo-backups/IMServer-pre-monorepo.bundle --all
```

3. Run the guarded conversion script:

```sh
CONFIRM_MONOREPO_FLATTEN=1 scripts/flatten-to-monorepo.sh
```

4. Review and commit all three projects:

```sh
git status --short
git commit -m "Create IM monorepo"
```

## Alternative: Preserve Full History In The Monorepo

If full independent commit history must be preserved, import the existing repositories with `git subtree` after their working trees are clean. That route is more complex and should be done before deleting nested `.git` directories.
