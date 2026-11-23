# Kuroneko

An open KVM over IP for the Sipeed NanoKVM-Go: the target computer's screen,
sound, keyboard and mouse in your browser. It is an Elixir application on
Nerves, on open mainline drivers, with no vendor software on the device's
processor.

* **Video** - the HDMI/DisplayPort input up to 3840 × 2160 at 30 fps, as
  H.264 for browsers with WebCodecs and MJPEG for the others
* **Sound** - what the target plays over HDMI or to its USB speaker, and
  your microphone as the target's USB microphone (over HTTPS)
* **Keyboard and mouse** - keys as you press them, an absolute mouse, a pen
  or a touch screen for Android and iPadOS, a relative mouse for BIOS setups
  and games; typing text, a mouse jiggler, Wake-on-LAN
* **USB devices** - which ones the target sees, as many as the device's
  USB endpoints take: keyboard and mouse, virtual disks, USB networks, a
  sound card in the formats you choose; the USB network's addresses
* **The LCD** - the device's address, the video input and its own load on
  its little screen, with touch and the button; the USB devices can be set
  there too
* **The device page** - its hardware, temperature, CPU, memory and network,
  the auxiliary port's lines, firmware updates on trial, restart
* **Settings** - the Wi-Fi to join, the SSH keys that may log in, the
  password
* **Login** - one password for the page and SSH, kept as a PBKDF2 hash and
  first set with a code from the LCD; five wrong ones lock the logins for a
  minute; HTTPS with a certificate the device makes itself

Kuroneko is the whole stack in the open, from the boot loader and the Linux
drivers to the page: use it as it is, read it, or build your own device on
it. It is made of [`nano_kvm_go`](https://github.com/cocoa-xu/nano_kvm_go),
the board's hardware,
[`kuroneko_gadget`](https://github.com/cocoa-xu/kuroneko_gadget), what the
target sees over USB, and the
[`nerves_system_nano_kvm_go`](https://github.com/cocoa-xu/nerves_system_nano_kvm_go)
Nerves system.

## Hardware

The Sipeed NanoKVM-Go+ (512 MB). The NanoKVM-Go with 256 MB is not supported
yet.

## Trying it

Kuroneko runs from a microSD card of its own. Keep the card the NanoKVM-Go
came with: putting it back brings the original software back, as Kuroneko
changes nothing outside its own card.

1. Download `kuroneko.fw` from the [releases](https://github.com/cocoa-xu/kuroneko/releases)
   and burn it to a card with [fwup](https://github.com/fwup-home/fwup)
   (`brew install fwup` on macOS), which finds the card itself:

   ```sh
   fwup kuroneko.fw
   ```

   To have it join your Wi-Fi from the first start, and to log in over SSH
   with your own key:

   ```sh
   NERVES_WIFI_SSID='my network' NERVES_WIFI_PASSPHRASE='my passphrase' \
     NERVES_SSH_AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" fwup kuroneko.fw
   ```

   Burning tools such as balenaEtcher take `kuroneko.img.gz` instead, without
   these settings.

2. Put the card in the NanoKVM-Go and connect it to the computer to control,
   USB and HDMI, as with its own software.

3. Its screen shows a setup code and where to find the page. On the
   computer it is connected to, open `http://nerves.local`: the USB network
   needs no driver on Linux and macOS. Any computer on its Wi-Fi can open
   the address the screen shows.

4. Choose a password, with the setup code. The password logs you in to the
   page and over SSH, with any user name.

5. **Settings** joins the Wi-Fi, sets the country whose Wi-Fi rules apply,
   and adds SSH keys.

HTTPS, which the microphone needs, uses a certificate the device made
itself: the browser asks once whether to trust it.

## Updating

New firmware goes over SSH, with your key or the password:

```sh
ssh -s nerves-XXXX.local fwup < kuroneko.fw
```

`XXXX` ends the device's serial number; the screen shows the whole name.
New firmware runs on trial: keep it on the device page, or with
`Nerves.Runtime.validate_firmware()` over SSH, within five minutes, or the
device goes back to the firmware before.

## Building

You need Elixir 1.20 and Erlang/OTP 29 with `nerves_bootstrap`:

```sh
git clone https://github.com/cocoa-xu/kuroneko
cd kuroneko
export MIX_TARGET=nano_kvm_go
mix deps.get
mix firmware
mix burn
```

`mix deps.get` fetches `nano_kvm_go`, `kuroneko_gadget` and
`nerves_system_nano_kvm_go` at the tags in `mix.exs`, and the Nerves system
prebuilt.

To work on them too, check them out next to `kuroneko` and set
`KURONEKO_DEPS_PATH=..`: the build takes them from there. A system that
differs from its release is then built with Buildroot, which takes Linux and
a while.

Two files of yours may go in `config/`, which git leaves out:

* `authorized_keys` - SSH keys built into your firmware, one per line
* `wifi.secret.exs` - your Wi-Fi:

  ```elixir
  import Config

  config :vintage_net,
    regulatory_domain: "US",
    config: [
      {"usb0", %{type: VintageNetDirect}},
      {"wlan0",
       %{
         type: VintageNetWiFi,
         vintage_net_wifi: %{networks: [%{key_mgmt: :wpa_psk, ssid: "my network", psk: "passphrase"}]},
         ipv4: %{method: :dhcp}
       }}
    ]
  ```

Without them the firmware is the one anybody can use: Wi-Fi, keys and the
password are then set on the device. Build firmware for others that way.

## Using it

**Disk…** on the KVM page holds the images and folders the target sees as
a USB drive, in `/data/images` on the device: upload them there from the
page, or over SFTP. An image goes in as what it holds, read from its own
structures: a disc image on the disc its format belongs on (ISO 9660 alone
a CD, UDF a DVD, UDF 2.50 and later a Blu-ray disc, any of them larger when
a smaller disc cannot hold it), any other image as a USB drive. The page
shows what it found under each image, and any of these can be forced.
What is in a drive goes in again after the device restarts, unless asked
not to. **USB…** gives the virtual disk up to 16 drives, which the target
sees at once, each with its own image or folder, and adds storage devices,
each a USB drive of its own, for BIOSes that boot only a device's first
drive. A CUE sheet goes in as a CD of its tracks, audio and data, from its
BIN, WAVE or AIFF files. A folder goes in as a drive made from it:
read-only, the target sees the folder as it was; writable, what the target
changes comes back to the folder when the drive is ejected. The drive is
exFAT, which holds files of any size, or FAT32 for BIOS updates, UEFI and
older systems, with files of at most 4 GiB.

The USB network puts the device in a /30 of 172.31.0.0/16 made from its
name. Where that is taken, the device page sets another address, such as
`10.55.0.1/24`: the target gets the next one. **USB…** adds more USB
networks, each in a /30 of its own.

The device has seven USB endpoints each way besides the control one, which
the USB devices share: a network takes two IN and one OUT, the keyboard and
each mouse one IN, a storage device one each way whatever its drives, the
microphone one IN and the speaker one OUT. **USB…** counts them as you
choose, and what does not fit is refused: drop the sound card, the mice or
even the USB network for more storage devices.

The memory for video and the NPU (192 and 64 MiB) changes at the next boot,
over SSH: `NanoKVMGo.CMA.put_sizes(%{video: 160, npu: 96})`. With
`trial: true` the next boot runs the new sizes on trial, kept the same way
as a new firmware.

The device keeps its state in `/data/kuroneko`: the password, the
certificate, the settings of the screen and the USB devices. SSH keys added
on the device are in `/data/nerves_ssh`, the Wi-Fi in `/data/vintage_net`.

## Known limits

* The NanoKVM-Go with 256 MB is not supported yet.
* Wi-Fi networks that need a user name (WPA2-Enterprise) and WEP ones
  cannot be joined from the page. Networks that offer WPA2 and WPA3 are
  joined with WPA2: WPA3 through this Wi-Fi chip is not proven yet.
* Firmware updates go over SSH: the page cannot upload them yet.

## License

Apache-2.0, see [LICENSE](LICENSE).
