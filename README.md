# Kuroneko

An open KVM over IP for the Sipeed NanoKVM-Go: the target computer's screen,
sound, keyboard and mouse in your browser. It is an Elixir application on
Nerves, on open mainline drivers, with no vendor software on the device.

* **Video** - the HDMI/DisplayPort input up to 3840 × 2160 at 30 fps, as
  H.264 for browsers with WebCodecs and MJPEG for the others
* **Sound** - what the target plays over HDMI or to its USB speaker, and
  your microphone as the target's USB microphone (over HTTPS)
* **Keyboard and mouse** - keys as you press them, an absolute mouse, a pen
  or a touch screen for Android and iPadOS, a relative mouse for BIOS setups
  and games; typing text, a mouse jiggler, Wake-on-LAN
* **USB devices** - which ones the target sees: keyboard and mouse, a
  virtual disk, a sound card in the formats you choose; the USB network's
  addresses
* **The LCD** - the device's address, the video input and its own load on
  its little screen, with touch and the button
* **The device page** - its hardware, temperature, CPU, memory and network,
  the auxiliary port's lines, firmware updates on trial, restart
* **Login** - one password, kept as a PBKDF2 hash; five wrong ones lock the
  page for a minute; HTTPS with a certificate the device makes itself

It is built from [`nano_kvm_go`](https://github.com/cocoa-xu/nano_kvm_go),
the board's hardware, and
[`kuroneko_gadget`](https://github.com/cocoa-xu/kuroneko_gadget), what the
target sees over USB, on the
[`nerves_system_nano_kvm_go`](https://github.com/cocoa-xu/nerves_system_nano_kvm_go)
Nerves system.

## Hardware

The Sipeed NanoKVM-Go+ (512 MB). The NanoKVM-Go with 256 MB is not supported
yet.

## Building

You need Elixir 1.20 and Erlang/OTP 29 with `nerves_bootstrap`, and Linux
for the first build of the Nerves system (Buildroot). Check the four
projects out side by side:

```sh
git clone https://github.com/cocoa-xu/kuroneko
git clone https://github.com/cocoa-xu/kuroneko_gadget
git clone https://github.com/cocoa-xu/nano_kvm_go
git clone https://github.com/cocoa-xu/nerves_system_nano_kvm_go

cd kuroneko
export MIX_TARGET=nano_kvm_go
mix deps.get
mix firmware
mix burn
```

Two files of yours stay out of the project:

* `config/wifi.secret.exs` - your Wi-Fi, else set it on the device with
  `VintageNetWiFi.quick_configure("ssid", "passphrase")`:

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

* `config/authorized_keys` - the SSH keys that may log in to the device,
  one per line; without it, your own `~/.ssh/id_*.pub`

## Using it

Open `http://nerves-XXXX.local`, where XXXX ends the device's serial number,
or its address on the USB network from the target computer. The first visit
sets the password: do it right away, on a network you trust.

Firmware updates go over SSH:

```sh
ssh -s nerves-XXXX.local fwup < _build/nano_kvm_go_dev/nerves/images/kuroneko.fw
```

New firmware runs on trial: confirm it on the device page, or with
`Nerves.Runtime.validate_firmware()` over SSH, within five minutes, or the
device goes back to the firmware before.

The device keeps its state in `/data/kuroneko`: the password, the
certificate, the settings of the screen and the USB devices. Devices that ran
the NanoKVM-Go test application (`nanokvm_hello`) keep theirs: it moves
there at the first start.

## License

Apache-2.0, see [LICENSE](LICENSE).
