#!/bin/bash
# Recreate the /tmp/lpac/build symlink structure for a prebuilt lpac binary.
# The binary we build has /tmp/lpac/build/... baked into its RPATH, so the
# shared objects are installed once under /usr/local/share/lpac and this
# one-shot (run from esim-prepare.service at boot, /tmp is volatile) re-creates
# the layout the loader expects. See docs/lpac.md for the alternative: build
# lpac with CMAKE_INSTALL_RPATH set properly and skip this entirely.
set -e
REAL=/usr/local/share/lpac
mkdir -p /tmp/lpac/build/{src,driver,euicc,utils,cjson}
ln -sf /usr/local/bin/lpac /tmp/lpac/build/src/lpac
for f in driver_apdu_qmi.so driver_apdu_mbim.so driver_apdu_pcsc.so driver_apdu_stdio.so driver_http_curl.so driver_http_stdio.so; do
  ln -sf $REAL/$f /tmp/lpac/build/driver/$f
done
for f in libeuicc-driver-loader.so libeuicc-driver-loader.so.2 libeuicc.so libeuicc.so.2 libeuicc-drivers.so; do
  ln -sf $REAL/$f /tmp/lpac/build/euicc/$f
  ln -sf $REAL/$f /tmp/lpac/build/driver/$f
done
ln -sf $REAL/liblpac-utils.so /tmp/lpac/build/utils/liblpac-utils.so
