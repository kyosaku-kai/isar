# This software is a part of ISAR.
# Copyright (C) 2026 contributors
#
# SPDX-License-Identifier: MIT

# host-tools.bbclass - Host-side recipe execution for ISAR
#
# Enables recipes to run tasks directly on the build host, without entering
# a Debian chroot. This is conceptually analogous to OE/Yocto's native.bbclass
# but dramatically simpler: no cross-toolchain, no sysroot population, no
# recipe-to-recipe staging dependency resolution.
#
# Designed for BSP support recipes that only need host tools (cp, sed, install,
# fdtput, python3) — the exact recipes that ISAR projects currently replicate
# by hand from OE BSP layers.
#
# Usage:
#   inherit host-tools
#
# Recipes implement do_compile() and do_install() as shell functions.
# do_install() should populate ${D} with the files to be staged.
# After do_install(), the class copies ${D} contents to ${STAGING_DIR_HOST}
# and ${DEPLOY_DIR_IMAGE}.

# Inherit patch support for SRC_URI patches
inherit patch

# Staging directory for host-tools recipe outputs.
# Recipes that depend on host-tools recipe outputs (via DEPENDS) can find
# files here. Organized per-machine to avoid cross-contamination.
STAGING_DIR_HOST = "${TMPDIR}/staging-host/${MACHINE}"

# Per-recipe deploy directory (temporary; sstate archives from here).
# Follows OE's deploy.bbclass pattern: per-recipe input dir, shared output dir.
HOST_TOOLS_DEPLOYDIR = "${WORKDIR}/deploy-${PN}"

# Install destination — recipes populate this in do_install().
D = "${WORKDIR}/image"

# Build directory for out-of-tree builds
B = "${WORKDIR}/build"

# OE compatibility shims — standard path variables that OE/Yocto defines
# in its bitbake.conf but ISAR does not. Required for unmodified OE BSP
# recipes to parse and execute in ISAR. Only defined when host-tools is
# inherited; no effect on normal ISAR recipes.

# Standard FHS path variables (match OE's bitbake.conf definitions)
prefix = "/usr"
exec_prefix = "/usr"
bindir = "${exec_prefix}/bin"
sbindir = "${exec_prefix}/sbin"
libdir = "${exec_prefix}/lib"
datadir = "${prefix}/share"
includedir = "${prefix}/include"
sysconfdir = "/etc"

# OE staging directory mappings — map OE staging variables to host-tools
# staging locations for recipes that reference them.
STAGING_DATADIR = "${STAGING_DIR_HOST}${datadir}"
STAGING_BINDIR_NATIVE = "${STAGING_DIR_HOST}${bindir}"
STAGING_LIBDIR_NATIVE = "${STAGING_DIR_HOST}${libdir}"
STAGING_INCDIR = "${STAGING_DIR_HOST}${includedir}"

# Suppress default dependency on sbuild chroot — host-tools recipes
# run directly on the build host and do not need Debian build infrastructure.
INHIBIT_DEFAULT_DEPS = "1"
DEPENDS ?= ""

# Machine-specific package arch — host-tools outputs are typically
# machine-specific (BSP firmware, flash configuration, etc.)
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Task chain: fetch → unpack → patch → configure → compile → install → deploy → build
#
# do_fetch and do_unpack are provided by base.bbclass (classes-global).
# do_patch is provided by patch.bbclass (inherited above).
# do_build is provided by base.bbclass.
# The remaining tasks are defined below.

do_configure () {
    :
}
do_configure[dirs] = "${B}"
addtask configure after do_patch before do_compile

do_compile () {
    :
}
do_compile[dirs] = "${B}"
addtask compile after do_configure before do_install

do_install () {
    :
}
do_install[dirs] = "${D}"
do_install[cleandirs] = "${D}"
addtask install after do_compile before do_deploy

# Deploy: copy installed files to the per-recipe deploy directory.
# The sstate system handles the copy from HOST_TOOLS_DEPLOYDIR (inputdirs)
# to STAGING_DIR_HOST (outputdirs). Do NOT write directly to
# STAGING_DIR_HOST here — that causes sstate overlap errors on rebuild.
do_deploy () {
    if [ -d "${D}" ] && [ "$(ls -A "${D}" 2>/dev/null)" ]; then
        cp -a "${D}"/* "${HOST_TOOLS_DEPLOYDIR}/"
    fi
}
do_deploy[dirs] = "${HOST_TOOLS_DEPLOYDIR}"
do_deploy[cleandirs] = "${HOST_TOOLS_DEPLOYDIR}"
addtask deploy after do_install before do_build

# sstate cache support for do_deploy.
# Uses per-recipe deploy dir as input (avoids corrupting the shared
# STAGING_DIR_HOST during sstate packaging, which moves files).
SSTATETASKS += "do_deploy"
do_deploy[sstate-inputdirs] = "${HOST_TOOLS_DEPLOYDIR}"
do_deploy[sstate-outputdirs] = "${STAGING_DIR_HOST}"

python do_deploy_setscene () {
    sstate_setscene(d)
}
addtask deploy_setscene

# Clean function to remove staged outputs
CLEANFUNCS += "host_tools_clean"
host_tools_clean () {
    if [ -d "${HOST_TOOLS_DEPLOYDIR}" ]; then
        rm -rf "${HOST_TOOLS_DEPLOYDIR}"
    fi
}
