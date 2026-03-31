# OE dos2unix.bbclass shim for ISAR.
#
# Provides CRLF-to-LF conversion task without requiring dos2unix-native
# recipe. The build host (kas-container) must have dos2unix installed,
# or recipes must override do_convert_crlf_to_lf with sed-based fallback.
#
# Note: tegra-binaries-36.5.0.inc overrides this function to only convert
# *.dts* files. This shim provides the default (convert all files).

do_convert_crlf_to_lf() {
    if command -v dos2unix >/dev/null 2>&1; then
        find ${S} -type f -exec dos2unix {} \;
    else
        find ${S} -type f -exec sed -i 's/\r$//' {} \;
    fi
}
addtask convert_crlf_to_lf after do_unpack before do_patch
