#!/bin/bash
# Builds pve-qemu-kvm with -rdp inside a pxvirt builder container, the standard way:
#   apt update && mk-build-deps --install --remove && make deb
# Optionally applies de-virtualization (anti-detection) patches before building,
# migrated from build_pve_qemu_pve9.sh.
# Usage: build-pve-qemu.sh PVE_QEMU_DIR LIBVDS_DEB_DIR [DEVIRT_DIR]
#   DEVIRT_DIR: directory holding anti-detection resources
#               (sedPatch-pve-qemu-kvm11-anti-dection.sh, smbios.h, smbios.c, bootsplash.jpg)
#               Defaults to PVE_QEMU_DIR. Set DEVIRT=0 to skip de-virtualization.
set -euxo pipefail
SRC=${1:?pve-qemu checkout}
DEBS=${2:?directory with libvds0/libvds-dev}
DEVIRT_DIR=${3:-$SRC}
DEVIRT=${DEVIRT:-1}
export DEBIAN_FRONTEND=noninteractive
APT_UPDATE="apt-get update --allow-releaseinfo-change"

$APT_UPDATE
apt-get install -y --no-install-recommends python3-venv git
apt-get install -y "$DEBS"/libvds0_*.deb "$DEBS"/libvds-dev_*.deb

cd "$SRC"
git config --global --add safe.directory '*'
# The Makefile only downloads the meson subprojects when it initializes the submodule
# itself; the checkout already did that, so download them here with QEMU's own meson.
if [ ! -d qemu/subprojects/keycodemapdb ]; then
  python3 -m venv /tmp/meson
  /tmp/meson/bin/pip install -q qemu/python/wheels/meson-*.whl
  (cd qemu && /tmp/meson/bin/meson subprojects download)
fi

# ---- De-virtualization patches (migrated from build_pve_qemu_pve9.sh) ----
# Apply anti-detection customizations inside qemu/ before make deb.
# The original script ran these from within qemu/, using ../ and ../../ relative
# paths for resources; here we resolve them via DEVIRT_DIR.
if [ "$DEVIRT" = "1" ] && [ -d "$DEVIRT_DIR" ]; then
  (
    cd qemu

    # 1. Anti-detection sed patch script
    cp "$DEVIRT_DIR/sedPatch-pve8-anti-dection.sh" .
    chmod +x sedPatch-pve8-anti-dection.sh
    bash sedPatch-pve8-anti-dection.sh

    # 2. SMBIOS replacement
    cp "$DEVIRT_DIR/smbios.h" include/hw/firmware/smbios.h
    cp "$DEVIRT_DIR/smbios.c" hw/smbios/smbios.c

    # 3. Seabios boot splash replacement
    cp "$DEVIRT_DIR/bootsplash.jpg" pc-bios/bootsplash.jpg
    sed -i "s/vgabios.bin/vgabios.bin',\n\t'bootsplash.jpg/g" pc-bios/meson.build
    sed -i 's/current_machine->boot_config.splash;/"\/usr\/share\/kvm\/bootsplash.jpg";/g' hw/nvram/fw_cfg.c

    # 4. IGD patch
    sed -i 's/!object_dynamic_cast/object_dynamic_cast/g' hw/vfio/igd.c

    # Optional: capture the applied patch for reference (not needed for build)
    git diff --submodule=diff > "$DEVIRT_DIR/qemu-autoGenPatch.patch" || true
  )
fi
# ---- End de-virtualization patches ----

$APT_UPDATE
mk-build-deps --install --remove --tool "apt-get -y --no-install-recommends" debian/control
DEB_BUILD_OPTIONS="parallel=$(nproc)" make deb
ls -la ./*.deb
