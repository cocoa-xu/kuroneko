# Changelog

## Unreleased

* The KVM as a Bluetooth keyboard and mouse, for a phone, tablet or computer
  that pairs with it: the device page's Bluetooth card opens pairing for 2
  minutes and lists the paired devices, which it can forget; the KVM page's
  Input button sends the keyboard and mouse there instead of to USB. It
  needs the system with BlueZ
* Text in the picture: Text on the KVM page, then a drag over a part of the
  picture, and the NanoKVM's NPU reads the text there (PP-OCRv5, Chinese and
  English) in about half a second; it can be copied or typed on the target.
  It needs the NPU, which the Go with 256 MiB leaves off by default, and the
  models in `priv/ocr`
* The video settings' Colour and Range (`color_matrix`, `color_range`) set
  the colour the HDMI bridge turns the picture into, with a system that can
  convert it, instead of only labelling it; Auto keeps the bridge's own,
  BT.709 at full range, and BT.601 shows the MJPEG view's strongest colours
  right

## v0.2.0 (2026-11-27)

* The device page has a USB section: the endpoints each USB device takes,
  of the seven IN and seven OUT the controller has, as bars that follow
  the changes being made; the devices the target sees, with the keyboard
  and mice, networks, storage devices and the sound card's formats, which
  apply together once they fit; and the drives, each with what is in it,
  to change or eject. USB… on the KVM page opens it, and the KVM page's
  echo cancellation for the microphone is in the Keys… menu
* One Disk… dialog for both pages: the device page opens it for a drive
* The H.264 stream's quality, as the stock firmware has it: presets on the
  KVM page (Auto, VBR of up to 8 Mbit/s; Highest, High, Medium and Low, CBR
  of 10, 5, 3 and 1 Mbit/s), and on the device page the rate control, the
  bitrate, the QP, the keyframe interval and a frame rate cap. Changes apply
  from the next frame, and stay across restarts. Needs nano_kvm_go's rate
  control
* Makers get Kuroneko's FAT32 formatter in their context, `format_fat`,
  so that a maker needs no dependency on Kuroneko, and tell how their
  image goes in with `as:` (`:disk`, `:cd`, `:dvd` or `:bd`), as
  `Kuroneko.Gadget.MassStorage.insert/2` takes it, instead of `cdrom:`
  and `disc:`

## v0.1.2 (2026-11-23)

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
* CUE sheets in Disk…: audio CDs and mixed-mode CDs, such as game discs,
  from BIN, WAVE or AIFF files. A sheet of one BIN goes in as it is, any
  other is laid out as one image first. Needs the Nerves system v0.1.3
* Makers: other modules can offer more ways an item of the library goes
  in a drive and make its image, such as a Windows installer's USB drive
  (`Kuroneko.VirtualDisk.Maker`). They are registered with `:disk_makers`
  in the config or at run time with `register_maker/1`, and their modes
  show in Disk…
* Eject asks the target to eject a disc it has locked, as a drive's button
  does; when it does not, the disc is taken out and the drive appears to
  the target anew, as it does when it turns from CD to USB drive or back
* USB… adds storage devices and USB networks, each by name, as many as
  the device's USB endpoints take, and counts the endpoints as you choose;
  the USB network can be turned off too.
  The drives in Disk… span every storage device, `GET /api/usb` tells each
  USB device with what each kind takes, and each further network gets a
  /30 of its own
* A USB devices page on the LCD: the keyboard and mice, the sound card,
  the virtual disk's drives, more storage devices and networks, a tap each,
  with the endpoints they take; Apply sets them at once
* The USB network's addresses can move, on the device page, where
  172.31.0.0/16 is taken
* A network's signal in dBm when the pointer rests on its bars, and a
  button to the Wi-Fi settings on the device page while there is no Wi-Fi
* The settings page's password card follows the SSH card, without a gap
* The Nerves system v0.1.3: the USB optical drive with CDs of tracks and
  with media events, and UDF and ISO 9660 for reading installer ISOs

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
