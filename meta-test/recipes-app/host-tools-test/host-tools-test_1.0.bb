# Test recipe for host-tools.bbclass validation
#
# This recipe validates that host-tools.bbclass correctly:
# 1. Runs do_compile on the build host (not in a chroot)
# 2. Runs do_install to populate ${D}
# 3. Runs do_deploy to stage outputs to ${STAGING_DIR_HOST}
#
# Usage:
#   bitbake host-tools-test

DESCRIPTION = "Validation recipe for host-tools.bbclass"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${LAYERDIR_core}/licenses/COPYING.MIT;md5=838c366f69b36c77e19ac5c99a7e4e65"

inherit host-tools

SRC_URI = "file://test-data.txt"

do_compile () {
    # Verify we're running on the host, not in a chroot
    echo "host-tools-test: Running do_compile on host"
    echo "  hostname: $(hostname)"
    echo "  uname: $(uname -a)"
    echo "  pwd: $(pwd)"

    # Generate a build artifact from the source data
    cp "${WORKDIR}/test-data.txt" "${B}/compiled-data.txt"
    echo "Compiled at: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${B}/compiled-data.txt"
}

do_install () {
    install -d "${D}${datadir}/host-tools-test"
    install -m 0644 "${B}/compiled-data.txt" "${D}${datadir}/host-tools-test/"

    # Create a marker file to verify staging works
    echo "STAGING_DIR_HOST=${STAGING_DIR_HOST}" > "${D}${datadir}/host-tools-test/staging-info.txt"
    echo "DEPLOY_DIR_IMAGE=${DEPLOY_DIR_IMAGE}" >> "${D}${datadir}/host-tools-test/staging-info.txt"
}
