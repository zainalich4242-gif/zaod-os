# ZAOD OS

ZAOD OS is a Debian Bookworm live desktop image with an XFCE desktop, first-boot
account setup, core applications, a `.zos` package engine, an app store, and a
removable-USB utility.

## Build

Run the numbered scripts in order from the repository root in an amd64 Debian or
Ubuntu environment. Parts 1 through 7 build and configure `./chroot`; Part 8
creates `ZAOD-OS.iso`.

```bash
sudo bash ./01-setup-kernel.sh
sudo bash ./02-setup-desktop.sh
sudo bash ./03-install-core-apps.sh
sudo bash ./04-setup-zos-engine.sh
sudo bash ./05-setup-app-store.sh
sudo bash ./06-setup-usb-tool.sh
sudo bash ./07-audit-polish-onboarding.sh
sudo bash ./08-build-final-iso.sh
```

The ISO is stored with Git LFS. Generated `chroot/` and `iso-staging/` trees are
build artifacts and are intentionally excluded from Git.

## Download

ZAOD OS 1.0: https://github.com/zainalich4242-gif/zaod-os/releases/download/v1.0/ZAOD-OS.iso

SHA256: `df306906a00acf8029a9736e65fae807cf42947ce89c3df43dcd34dffbd21148`