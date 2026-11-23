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
             %{ssid: "home", signal_percent: 85, band: "5 GHz", security: :wpa2_wpa3},
             %{ssid: "cafe", signal_percent: 60, band: "2.4 GHz", security: :open},
             %{ssid: "office", signal_percent: 60, band: "5 GHz", security: :enterprise},
             %{ssid: "old", signal_percent: 10, band: "2.4 GHz", security: :wep}
           ]
  end

  test "WPA2, WPA3 or both" do
    assert [%{security: :wpa3}] = WiFi.networks([ap("new", 70, 5745, [:wpa2_sae_ccmp, :sae])])

    assert [%{security: :wpa2}] =
             WiFi.networks([ap("old", 70, 5745, [:wpa2_psk_ccmp, :wpa_psk_ccmp])])
  end

  test "WPA2 with a passphrase, WPA3 only where the network offers nothing else" do
    assert WiFi.recipe(nil, :open) == :open
    assert WiFi.recipe("", :wpa2) == :open
    assert WiFi.recipe("passphrase", :wpa2) == :wpa2
    assert WiFi.recipe("passphrase", :wpa2_wpa3) == :wpa2
    assert WiFi.recipe("passphrase", nil) == :wpa2
    assert WiFi.recipe("passphrase", :wpa3) == :wpa3
    assert WiFi.recipe(String.duplicate("aB3", 21) <> "f", :wpa3) == :wpa2_key
  end

  test "a key of 64 hex digits joins as WPA2, also on the host" do
    key = String.duplicate("0123456789abcdef", 4)

    assert {:ok,
            %{vintage_net_wifi: %{networks: [%{key_mgmt: :wpa_psk, ssid: "home", psk: ^key}]}}} =
             WiFi.config("home", key)

    assert {:ok, %{vintage_net_wifi: %{networks: [%{scan_ssid: 1}]}}} =
             WiFi.config("lab", key, hidden: true)

    assert WiFi.config("", key) == {:error, :ssid_too_short}
    assert WiFi.config(String.duplicate("x", 33), key) == {:error, :ssid_too_long}
  end

  test "the host has no Wi-Fi" do
    assert WiFi.config("home", "passphrase") == {:error, :no_wifi}
    refute WiFi.configured?()
    assert %{present: false, networks: [], network: nil, country: "00"} = WiFi.overview()
    assert WiFi.set_country("JP") == {:error, :no_wifi}
  end

  test "a country is two letters, or 00 for rules that hold everywhere" do
    assert WiFi.country_code("jp") == {:ok, "JP"}
    assert WiFi.country_code("00") == {:ok, "00"}

    for code <- ["J", "JPN", "J1", "", nil, 81] do
      assert WiFi.country_code(code) == {:error, :invalid_country}, inspect(code)
    end
  end

  test "the country goes with the network and stays when there is none" do
    joined = %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{networks: [%{ssid: "home"}]},
      ipv4: %{method: :dhcp}
    }

    assert WiFi.with_country(joined, "JP") == %{
             joined
             | vintage_net_wifi: %{networks: [%{ssid: "home"}], regulatory_domain: "JP"}
           }

    none = %{type: VintageNetWiFi, vintage_net_wifi: %{networks: [], regulatory_domain: "JP"}}
    assert WiFi.with_country(%{type: VintageNetWiFi}, "JP") == none
    assert WiFi.with_country(%{type: VintageNet.Technology.Null}, "JP") == none

    key = String.duplicate("0123456789abcdef", 4)
    assert {:ok, %{vintage_net_wifi: %{regulatory_domain: "00"}}} = WiFi.config("home", key)
  end
end
