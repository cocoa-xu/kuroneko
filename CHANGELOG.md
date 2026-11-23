# Changelog

## Unreleased

* The settings page scans on its own while it is open, every ten seconds,
  and keeps each network for five minutes after it was last seen: a scan
  that misses a network no longer hides it
* The country whose Wi-Fi rules apply, on the settings page
* The device page gives the input's frame rate in FPS
* Disk… on the KVM page: images and folders for the target's USB drive,
  uploaded from the page. An image goes in as what it holds, read from its
  file systems: a CD, a DVD (Windows installers too, past the CD's 2.3 GB)
  or a Blu-ray disc, or a USB drive, and any of these can be forced. A
  folder goes in as an exFAT drive, or FAT32 for BIOS updates, UEFI and
  older systems, read-only or writable, and a writable one's changes come
  back to it when ejected. What is in a drive goes in again after a
  restart, unless inserted with `remember: false`. Up to 16 drives at
  once, set in USB…, each with its own image or folder
* USB… adds storage devices and USB networks, each by name, as many as
  the device's USB endpoints take, and counts the endpoints as you choose.
  The drives in Disk… span every storage device, `GET /api/usb` tells each
  USB device with what each kind takes, and each further network gets a
  /30 of its own
* The USB network's addresses can move, on the device page, where
  172.31.0.0/16 is taken
* A network's signal in dBm when the pointer rests on its bars, and a
  button to the Wi-Fi settings on the device page while there is no Wi-Fi
* The settings page's password card follows the SSH card, without a gap

## v0.1.1 (2026-11-23)

* The data partition takes the rest of the card, also on a card burned
  from `kuroneko.img.gz`, where it had 512 MiB: the Nerves system v0.1.1
  grows it at boot and keeps its files
* Builds on its own: `nano_kvm_go`, `kuroneko_gadget` and the Nerves system
  come from GitHub at their release tags, or from the checkouts next to it
  with `KURONEKO_DEPS_PATH=..`

## v0.1.0 (2026-11-21)

First version:

* The KVM in the browser: H.264 and MJPEG video, the target's sound, its
  USB microphone, keyboard, mouse, pen and touch input, typing,
  Wake-on-LAN, a mouse jiggler
* The USB devices the target sees, the LCD's pages, the device page
* The settings page: Wi-Fi, SSH keys, the password
* One password for the page and SSH, first set with a code from the LCD;
  HTTPS with a certificate of the device's own; firmware updates on trial
* Wi-Fi and SSH keys set when the card is burned, as in Nerves Livebook
