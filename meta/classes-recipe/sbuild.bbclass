# This software is a part of Isar.
# Copyright (C) 2021 ilbers GmbH

SCHROOT_CONF ?= "/etc/schroot"

SCHROOT_MOUNTS ?= ""

# schroot_end_session() retries a transient-busy `schroot -e` (a build child not
# yet reaped still holding an fd under a session bind mount). When set to "1" it
# ADDITIONALLY lazy-unmounts any mount still busy after the retries. OFF by
# default: the strict umount stays the default so a genuinely forgotten
# sub-mount still fails loudly (upstream's leak-detection philosophy, ilbers#125);
# a consumer who accepts the lazy-umount trade-off opts in explicitly.
SCHROOT_END_LAZY_UMOUNT_FALLBACK ??= "0"

inherit crossvars

SBUILD_CHROOT ?= "${DEBDISTRONAME}-${SCHROOT_USER}-${ISAR_BUILD_UUID}-${@os.getpid()}"

SBUILD_CONF_DIR ?= "${SCHROOT_CONF}/${SBUILD_CHROOT}"
SCHROOT_CONF_FILE ?= "${SCHROOT_CONF}/chroot.d/${SBUILD_CHROOT}"

SBUILD_CONFIG="${WORKDIR}/sbuild.conf"

# Lockfile available for all the users
SCHROOT_LOCKFILE = "/tmp/schroot.lock"

schroot_create_configs() {
    mkdir -p "${TMPDIR}/schroot-overlay"
    echo "Creating ${SCHROOT_CONF_FILE}"
    sudo -s <<'EOSUDO'
        set -e

        cat << EOF > "${SCHROOT_CONF_FILE}"
[${SBUILD_CHROOT}]
type=directory
directory=${SCHROOT_DIR}
profile=${SBUILD_CHROOT}
users=${SCHROOT_USER}
groups=root,sbuild
root-users=${SCHROOT_USER}
root-groups=root,sbuild
source-root-users=${SCHROOT_USER}
source-root-groups=root,sbuild
union-type=overlay
union-overlay-directory=${TMPDIR}/schroot-overlay
preserve-environment=true
EOF

        # Prepare mount points
        cp -rf "${SCHROOT_CONF}/sbuild" "${SBUILD_CONF_DIR}"
        sbuild_fstab="${SBUILD_CONF_DIR}/fstab"

        fstab_baseapt="${REPO_BASE_DIR} /base-apt none rw,bind,private 0 0"
        grep -qxF "${fstab_baseapt}" ${sbuild_fstab} || echo "${fstab_baseapt}" >> ${sbuild_fstab}

        fstab_pkgdir="${WORKDIR} /home/builder/${BPN} none rw,bind,private 0 0"
        grep -qxF "${fstab_pkgdir}" ${sbuild_fstab} || echo "${fstab_pkgdir}" >> ${sbuild_fstab}

        if [ -d ${DL_DIR} ]; then
            fstab_downloads="${DL_DIR} /downloads none rw,bind,private 0 0"
            grep -qxF "${fstab_downloads}" ${sbuild_fstab} || echo "${fstab_downloads}" >> ${sbuild_fstab}
        fi
EOSUDO
}

schroot_delete_configs() {
    (flock -x 9
    set -e
    sudo -s <<'EOSUDO'
        set -e
        if [ -d "${SBUILD_CONF_DIR}" ]; then
            echo "Removing ${SBUILD_CONF_DIR}"
            rm -rf "${SBUILD_CONF_DIR}"
        fi
        echo "Removing ${SCHROOT_CONF_FILE}"
        rm -f "${SCHROOT_CONF_FILE}"
EOSUDO
    ) 9>"${SCHROOT_LOCKFILE}"
}

sbuild_add_env_filter() {
    [ -w ${SBUILD_CONFIG} ] || touch ${SBUILD_CONFIG}

    if ! grep -q "^\$environment_filter =" ${SBUILD_CONFIG}; then
        echo "\$environment_filter = [" >> ${SBUILD_CONFIG}
        echo "];" >> ${SBUILD_CONFIG}
    fi

    FILTER=${1}

    sed -i -e "/'\^${FILTER}\\$/d" \
        -e "/^\$environment_filter =.*/a '^${FILTER}\$'," ${SBUILD_CONFIG}
}

sbuild_export() {
    [ -w ${SBUILD_CONFIG} ] || touch ${SBUILD_CONFIG}

    if ! grep -q "^\$build_environment =" ${SBUILD_CONFIG}; then
        echo "\$build_environment = {" >> ${SBUILD_CONFIG}
        echo "};" >> ${SBUILD_CONFIG}
    fi

    VAR=${1}; shift
    VAR_LINE="'${VAR}' => '${@}',"

    sed -i -e "/^'${VAR}' =>/d" ${SBUILD_CONFIG} \
        -e "/^\$build_environment =.*/a ${VAR_LINE}" ${SBUILD_CONFIG}
}

insert_mounts() {
    sudo -s <<'EOSUDO'
        set -e
        for mp in ${SCHROOT_MOUNTS}; do
            FSTAB_LINE="${mp%%:*} ${mp#*:} none rw,bind,private 0 0"
            grep -qxF "${FSTAB_LINE}" ${SBUILD_CONF_DIR}/fstab || \
                echo "${FSTAB_LINE}" >> ${SBUILD_CONF_DIR}/fstab
        done
EOSUDO
}

remove_mounts() {
    sudo -s <<'EOSUDO'
        set -e
        for mp in ${SCHROOT_MOUNTS}; do
            FSTAB_LINE="${mp%%:*} ${mp#*:} none rw,bind,private 0 0"
            sed -i "\|${FSTAB_LINE}|d" ${SBUILD_CONF_DIR}/fstab
        done
EOSUDO
}

# List the processes holding an fd / cwd / root / exe anywhere under a mount
# tree, as "pid(comm)" tokens. Pure /proc scan (readlink), no fuser/lsof
# dependency; run under sudo so it can read every process's /proc entries. Used
# by schroot_end_session to wait for mount quiescence AND to NAME the holder in
# the build log. Takes the mount-tree root as $1.
schroot_mount_holders() {
    local mount_root="${1}"
    sudo bash -c '
        root="$1"
        for p in /proc/[0-9]*; do
            pid="${p#/proc/}"
            held=""
            for link in cwd root exe; do
                tgt="$(readlink "$p/$link" 2>/dev/null)" || continue
                case "$tgt" in "$root"|"$root"/*) held=1; break;; esac
            done
            if [ -z "$held" ] && [ -d "$p/fd" ]; then
                for fd in "$p"/fd/*; do
                    tgt="$(readlink "$fd" 2>/dev/null)" || continue
                    case "$tgt" in "$root"|"$root"/*) held=1; break;; esac
                done
            fi
            [ -n "$held" ] && echo "${pid}($(cat "$p/comm" 2>/dev/null))"
        done
    ' _ "${mount_root}" 2>/dev/null | sort -u | tr "\n" " "
}

# Robustly end a schroot session. schroot's setup-stop runs the bundled
# 10mount teardown, which umounts the session's bind mounts (WORKDIR, rootfs,
# DEPLOY_DIR_IMAGE, isar-apt). A transient holder of an open fd under one of
# those mounts - observed with the imager's do_image_uki (a backgrounded dpkg
# man-db trigger, or the ukify/sbsign child not yet fully reaped) - makes the
# umount fail EBUSY ("target is busy") at the instant teardown runs, so
# `schroot -e` exits non-zero and, under the task's `set -e`, hard-fails the
# task even though the artifact was already written and is correct.
#
# ROOT CAUSE: a process spawned during the build step detached from ISAR's
# synchronous wait (schroot -r blocks on its direct child, but a reparented /
# daemonized grandchild escapes it) and is still alive, holding an fd under a
# session bind mount, when the session ends. schroot is not a strong boundary
# (shared host PID namespace + host bind mounts), so such a process can outlive
# the "session" and pin a host-visible mount. The structural fix is the unshare
# / PID-namespace chroot mode (post-v1.1 upstream), tracked as a separate task.
#
# INTERIM FIX (deterministic quiescence, NOT a blind retry): wait for the actual
# condition - no process holding a mount under the session tree - polling with a
# timeout, and LOG the holders each poll so the escaping process is NAMED in the
# build log (root-cause diagnostics). Then end the session once, strictly: a
# mount still busy after the wait is genuinely stuck and `schroot -e` fails
# loudly, preserving upstream's forgotten-sub-mount detection (ilbers#125).
#
# SCHROOT_END_LAZY_UMOUNT_FALLBACK=1 (opt-in, default 0) additionally
# lazy-unmounts any mount still busy after the wait, trading that loud failure
# for completion; even then it LOGS every mount it force-detaches.
#
# Takes the session id as $1. Callers must use this instead of a bare
# `schroot -e` wherever a session bind-mounts a directory a build step touches.
schroot_end_session() {
    local sid="${1}"
    local session_mount="/var/run/schroot/mount/${sid}"
    local waited=0
    local max_wait=30
    local holders=""

    sync
    while [ "${waited}" -lt "${max_wait}" ]; do
        holders="$(schroot_mount_holders "${session_mount}")"
        [ -z "${holders}" ] && break
        echo "schroot teardown ${sid}: mount held, waiting to quiesce (${waited}s/${max_wait}s): ${holders}"
        sync
        sleep 2
        # NOTE: BitBake's bundled shell parser (bb/pysh) does NOT implement the
        # POSIX arithmetic expansion $(( ... )) and raises NotImplementedError at
        # PARSE time for any recipe/class that inherits this function - it has no
        # bearing on runtime. Use `expr` (plain command substitution, which the
        # parser does support) instead. `waited` starts at 0 and only increases,
        # so `expr` never yields 0 and cannot trip the task's `set -e` via its
        # result-is-zero exit status.
        waited=$(expr "${waited}" + 2)
    done
    if [ -n "${holders}" ]; then
        echo "schroot teardown ${sid}: still held after ${max_wait}s by: ${holders}"
    fi

    if schroot -e -c "${sid}" 2>/dev/null; then
        return 0
    fi

    if [ "${SCHROOT_END_LAZY_UMOUNT_FALLBACK}" = "1" ]; then
        # Opt-in last resort: lazily detach any bind mounts still lingering under
        # the session mount dir (deepest first). umount -l detaches immediately
        # and frees the path once the stray fd closes. Each detach is LOGGED so a
        # genuine forgotten sub-mount is still visible in the build log.
        echo "schroot teardown ${sid}: still busy after the quiesce wait; SCHROOT_END_LAZY_UMOUNT_FALLBACK=1, forcing lazy-unmount"
        if [ -d "${session_mount}" ]; then
            awk -v p="${session_mount}" '$2 == p || index($2, p "/") == 1 { print $2 }' /proc/mounts \
                | sort -r \
                | while read -r mp; do
                    echo "  lazy-unmounting still-busy mount: ${mp}"
                    sudo umount -l "${mp}" 2>/dev/null || true
                done
        fi
    fi

    # Final attempt. In the default (strict) mode a mount still busy here is
    # genuinely stuck and this fails loudly, as upstream intends. With the
    # fallback enabled the lazy-detach above has freed the path, so this succeeds.
    schroot -e -c "${sid}"
}
# schroot_end_session calls schroot_mount_holders only via command substitution
# ("$(schroot_mount_holders ...)"). BitBake's shell codeparser (bb.codeparser.
# ShellParser) does NOT descend into $(...) embedded in an assignment word, so it
# never records schroot_mount_holders as an exec dependency and omits its
# definition from the generated run.do_image_* script - the function then fails
# at runtime with "schroot_mount_holders: not found" (exit 127). Declare the
# dependency explicitly: emit_func() unions [vardeps] into the emitted-function
# set, which both ships the definition AND ties the caller's signature to it.
schroot_end_session[vardeps] += "schroot_mount_holders"

schroot_configure_ccache() {
    mkdir -p "${CCACHE_DIR}"
    sudo -s <<'EOSUDO'
        set -e

        sbuild_fstab="${SBUILD_CONF_DIR}/fstab"

        fstab_ccachedir="${CCACHE_DIR} /ccache none rw,bind,private 0 0"
        grep -qxF "${fstab_ccachedir}" ${sbuild_fstab} || echo "${fstab_ccachedir}" >> ${sbuild_fstab}

        (flock 9
        [ -w ${CCACHE_DIR}/sbuild-setup ] || cat << END > ${CCACHE_DIR}/sbuild-setup
#!/bin/sh
export PATH="\$PATH_PREPEND:\$PATH"
exec "\$@"
END
        chmod a+rx ${CCACHE_DIR}/sbuild-setup
        ) 9>"${CCACHE_DIR}/sbuild-setup.lock"

        echo "command-prefix=/ccache/sbuild-setup" >> "${SCHROOT_CONF_FILE}"
EOSUDO
}

sbuild_dpkg_log_export() {
    export dpkg_partial_log="${1}"

    ( flock 9
    set -e
    cat ${dpkg_partial_log} >> ${SCHROOT_DIR}/tmp/dpkg_common.log
    )  9>"${SCHROOT_DIR}/tmp/dpkg_common.log.lock"
}
