import Config

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Enable the system startup guard to check that all OTP applications
# started. If they didn't and you're on a Nerves system that supports
# test runs of new firmware, the firmware will automatically roll
# back to the previous version. Delete this if implementing your own
# way of validating that firmware is good.
config :nerves_runtime, startup_guard_enabled: false

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without a real-time clock.
config :nerves, :erlinit, update_clock: true

# Default to not starting so that the console logger isn't started. See
# runtime.exs for logger configuration.
config :logger, :default_handler, false

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://nerves-ssh.hexdocs.pm/readme.html for general SSH configuration
# * See https://ssh-subsystem-fwup.hexdocs.pm/readme.html for firmware updates

# Who may log in: any user name with the web page's password, and the keys
# added on its settings page or when the card was burned (Kuroneko.SSH).
# Keys of your own, one per line in config/authorized_keys, which is kept
# out of the project, are built into the firmware. Firmware for others is
# built without that file: nothing else here takes keys from the computer.
authorized_keys =
  case File.read(Path.join(__DIR__, "authorized_keys")) do
    {:ok, keys} -> keys |> String.split("\n", trim: true) |> Enum.reject(&(&1 =~ ~r/^\s*#/))
    {:error, _reason} -> []
  end

config :nerves_ssh,
  authorized_keys: authorized_keys,
  daemon_option_overrides: [
    pwdfun: &Kuroneko.SSH.check_password/4,
    auth_method_kb_interactive_data:
      {~c"Kuroneko", ~c"The password of the device's web page.", ~c"Password: ", false}
  ]

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
# usb0 (USB gadget) and wlan0. The Wi-Fi is set on the settings page, when
# the card is burned (config/provisioning.conf) or in IEx with
# VintageNetWiFi.quick_configure("ssid", "passphrase"); your own may go in
# config/wifi.secret.exs, which is kept out of the project.
config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

if File.exists?(Path.join(__DIR__, "wifi.secret.exs")) do
  import_config "wifi.secret.exs"
end

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, "nerves"],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "epmd",
      transport: "tcp",
      port: 4369
    }
  ]

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
