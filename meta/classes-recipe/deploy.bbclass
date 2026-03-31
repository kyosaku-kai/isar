# OE deploy.bbclass shim for ISAR host-tools recipes.
#
# In OE/Yocto, deploy.bbclass provides DEPLOYDIR and do_deploy task
# infrastructure for recipes that stage files to the deploy directory.
# In ISAR, host-tools.bbclass provides equivalent functionality.
#
# This shim maps the OE deploy pattern to host-tools: DEPLOYDIR is aliased
# to HOST_TOOLS_DEPLOYDIR so recipes that write to ${DEPLOYDIR} stage to
# the same location as host-tools' sstate system.
#
# Recipes that override do_deploy() should install files into
# ${HOST_TOOLS_DEPLOYDIR} with proper subdirectory structure (e.g.,
# ${HOST_TOOLS_DEPLOYDIR}${datadir}/tegraflash/) so sstate copies them
# to ${STAGING_DIR_HOST}/usr/share/tegraflash/.

inherit host-tools

DEPLOYDIR = "${HOST_TOOLS_DEPLOYDIR}"
