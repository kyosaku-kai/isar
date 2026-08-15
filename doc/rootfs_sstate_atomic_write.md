# Atomic write of the rootfs sstate tarball

## Motivation

`rootfs_install_sstate_prepare` in `meta/classes-recipe/rootfs.bbclass` packs the target
rootfs into `rootfs.tar`, which BitBake then seals into the `do_rootfs_install` sstate
package (`sstate:...:_rootfs_install.tar.zst`). When that sstate package is published to a
shared mirror (e.g. an S3 sstate cache), every build whose signature resolves to that key
restores the tarball via `rootfs_install_sstate_finalize`.

The original code wrote the tarball **directly to its final name** with no temp file and no
error handling:

```sh
sudo tar -C ${WORKDIR}/mnt -cpSf rootfs.tar $lopts ${SSTATE_TAR_ATTR_FLAGS} rootfs
```

If that `tar` was interrupted (the build cancelled/timed-out, the process killed) or failed
part-way (e.g. `ENOSPC`), a **truncated `rootfs.tar` was left on disk under the final name**.
The outer sstate packaging (`sstate_create_package`) is itself atomic (`mktemp` + `ln`), so
it faithfully sealed the truncated `rootfs.tar` into a **structurally valid** `.tar.zst` and
published it. The corruption is invisible to an integrity test on the outer package
(`zstd -t` passes; `tar -tf` of the outer lists `rootfs.tar` fine) - it only surfaces later,
deterministically, when `rootfs_install_sstate_finalize` unpacks the inner tarball:

```
tar: Unexpected EOF in archive
tar: Error is not recoverable: exiting now
```

Because a mirror sync that compares size+mtime never replaces an already-present object, such
a poisoned key does **not self-heal**: it breaks every consumer until it is manually purged.

## Fix

Write the tarball to a temporary name and rename it into place **only after `tar` fully
succeeds**. A same-directory `mv` is a `rename(2)`, which is atomic, so the final `rootfs.tar`
only ever exists with complete content. BitBake runs task shell functions with `set -e`, so a
non-zero `tar` exit aborts the task **before** the rename - the sstate package is never
created, and there is nothing partial to publish.

```sh
sudo tar -C ${WORKDIR}/mnt -cpSf rootfs.tar.tmp $lopts ${SSTATE_TAR_ATTR_FLAGS} rootfs
sudo chown $(id -u):$(id -g) rootfs.tar.tmp
mv rootfs.tar.tmp rootfs.tar
```

The cleanup is also hardened: the `EXIT` trap now releases the bind-mount and removes any
leftover `rootfs.tar.tmp` (as root, since an interrupted `tar` leaves a root-owned temp),
in addition to removing the mount directories. On the success path the temp has already been
renamed away, so the removal is a no-op.

### Before / after

| Scenario | Before | After |
|----------|--------|-------|
| `tar` succeeds | `rootfs.tar` written, mount unmounted, chowned | `rootfs.tar.tmp` written, chowned, renamed to `rootfs.tar`; mount released in trap |
| `tar` killed / `ENOSPC` | truncated `rootfs.tar` under final name -> sealed + published | only `rootfs.tar.tmp` (removed by trap); task fails; no sstate package |
| leaked bind-mount on failure | possible (umount only on success path) | released in the `EXIT` trap |

This mirrors the atomic `mktemp` + rename idiom already used by `sstate_create_package` in
`meta/classes-global/sstate.bbclass`, rather than introducing a new pattern.

## Notes for upstreaming

- This change is against the direct-`sudo tar` form on `master`. A separate refactor on the
  `next` branch moves this function to `run_privileged_heredoc`; the same tmp+rename +
  fail-closed guarantee should be preserved there.
- No new configuration knob is introduced; the behaviour change is unconditional and safe:
  a successful build produces an identical `rootfs.tar`, only via an atomic rename.

## Validation

- Negative: simulate a failing/short `tar` and confirm the function exits non-zero and leaves
  **no** `rootfs.tar` (only the temp, which the trap removes) - so no sstate package can be
  sealed from a partial tarball.
- Positive: a normal image build still produces a valid `do_rootfs_install` sstate package and
  restores correctly (no regression).
