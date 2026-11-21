defmodule Kuroneko.WiFiTest do
  use ExUnit.Case, async: true

  alias Kuroneko.WiFi

  defp ap(ssid, percent, mhz, flags),
    do: %{
      ssid: ssid,
      signal_percent: percent,
      frequency: mhz,
      flags: flags,
      bssid: "02:00:00:00:00:01"
    }

  test "one network per name with its strongest access point, the strongest first" do
    access_points = [
      ap("home", 40, 2437, [:wpa2_psk_ccmp, :ess]),
      ap("home", 85, 5180, [:wpa2_psk_sae_ccmp, :sae, :ess]),
      ap("cafe", 60, 2412, [:ess]),
      ap("office", 60, 5500, [:wpa2_eap_ccmp, :ess]),
      ap("old", 10, 2462, [:wep, :ess]),
      ap("", 99, 2412, [:wpa2_psk_ccmp])
    ]

    assert WiFi.networks(access_points) == [
             %{ssid: "home", signal_percent: 85, band: "5 GHz", security: :personal},
             %{ssid: "cafe", signal_percent: 60, band: "2.4 GHz", security: :open},
             %{ssid: "office", signal_percent: 60, band: "5 GHz", security: :enterprise},
             %{ssid: "old", signal_percent: 10, band: "2.4 GHz", security: :wep}
           ]
  end

  test "WPA3 only is a passphrase network too" do
    assert [%{security: :personal}] = WiFi.networks([ap("new", 70, 5745, [:wpa2_sae_ccmp, :sae])])
  end

  test "the host has no Wi-Fi" do
    assert WiFi.config("home", "passphrase") == {:error, :no_wifi}
    refute WiFi.configured?()
    assert %{present: false, networks: [], network: nil} = WiFi.overview()
  end
end
