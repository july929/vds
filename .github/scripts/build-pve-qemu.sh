#!/bin/bash
set -euxo pipefail
SRC=${1:?pve-qemu checkout}
DEBS=${2:?directory with libvds0/libvds-dev}
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

# --- Optional de-virtualization patches -----------------------------------
if [ "${DEVIRT_ENABLE:-0}" = "1" ]; then
  : "${DEVIRT_PATCH_DIR:?DEVIRT_PATCH_DIR must point to the de-virt patch files}"
  cd qemu

  cp "$DEVIRT_PATCH_DIR/sedPatch-pve-qemu-kvm11-anti-dection.sh" ./
  chmod +x sedPatch-pve-qemu-kvm11-anti-dection.sh
  bash sedPatch-pve-qemu-kvm11-anti-dection.sh

  cp "$DEVIRT_PATCH_DIR/smbios.h" include/hw/firmware/smbios.h
  cp "$DEVIRT_PATCH_DIR/smbios.c" hw/smbios/smbios.c

  cp "$DEVIRT_PATCH_DIR/bootsplash.jpg" pc-bios/bootsplash.jpg
  sed -i "s/vgabios.bin/vgabios.bin',\n\t'bootsplash.jpg/g" pc-bios/meson.build
  sed -i 's/current_machine->boot_config.splash;/"\/usr\/share\/kvm\/bootsplash.jpg";/g' hw/nvram/fw_cfg.c

  sed -i 's/!object_dynamic_cast/object_dynamic_cast/g' hw/vfio/igd.c

  # Save the applied changes as a patch for auditability, then return to the
  # source root. Do NOT run `git checkout .` here: the changes must survive
  # into `make deb`.
  git diff --submodule=diff > ../qemu-devirt.patch
  cd ..
  cd ..
fi
# --- End optional de-virtualization patches -------------------------------

$APT_UPDATE
mk-build-deps --install --remove --tool "apt-get -y --no-install-recommends" debian/control
DEB_BUILD_OPTIONS="parallel=$(nproc)" make deb
ls -la ./*.deb
