#!/bin/bash
# Recreate the /tmp/lpac-build/build symlink structure for the lpac build
# with the AT (AT+CSIM) APDU driver used on the DW5821e. The binary carries
# /tmp/lpac-build/build in its RPATH; the real files live under
# /usr/local/share/lpac-at. See docs/lpac.md — a build with a proper install
# RPATH does not need this.
set -e
REAL=/usr/local/share/lpac-at
mkdir -p /tmp/lpac-build/build/{src,driver,euicc,utils}
ln -sf $REAL/lpac /tmp/lpac-build/build/src/lpac
for f in driver_apdu_at.so driver_apdu_at_csim.so driver_apdu_stdio.so \
         driver_http_curl.so driver_http_stdio.so \
         libeuicc-driver-loader.so libeuicc-driver-loader.so.2 \
         libeuicc-drivers.so libeuicc-drivers.so.2; do
  [ -f "$REAL/$f" ] && ln -sf "$REAL/$f" "/tmp/lpac-build/build/driver/$f"
done
for f in libeuicc.so libeuicc.so.2; do
  [ -f "$REAL/$f" ] && ln -sf "$REAL/$f" "/tmp/lpac-build/build/euicc/$f"
done
ln -sf "$REAL/liblpac-utils.so" /tmp/lpac-build/build/utils/liblpac-utils.so
echo "[lpac-setup] symlinks created in /tmp/lpac-build/build/"
