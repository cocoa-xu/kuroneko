defmodule Kuroneko.ProvisioningTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Provisioning

  test "joins the card's Wi-Fi while none is configured, or always when forced" do
    card = %{"wifi_ssid" => "example", "wifi_passphrase" => "passphrase"}

    assert Provisioning.wifi(card, false) == {:join, "example", "passphrase"}
    assert Provisioning.wifi(card, true) == :none

    for force <- ["true", "1", "yes"] do
      assert Provisioning.wifi(Map.put(card, "wifi_force", force), true) ==
               {:join, "example", "passphrase"}
    end

    for force <- [nil, "", "false", "FALSE"] do
      assert Provisioning.wifi(Map.put(card, "wifi_force", force), true) == :none
    end
  end

  test "an open network has no passphrase; no name, no network" do
    assert Provisioning.wifi(%{"wifi_ssid" => "cafe"}, false) == {:join, "cafe", nil}
    assert Provisioning.wifi(%{"wifi_ssid" => "", "wifi_force" => "true"}, false) == :none
    assert Provisioning.wifi(%{}, false) == :none
  end

  test "SSH keys one per line, without blank lines and comments" do
    text = "ssh-ed25519 AAAA one\r\n\n  # a comment\nssh-rsa AAAA two  \n"

    assert Provisioning.ssh_keys(%{"ssh_authorized_keys" => text}) == [
             "ssh-ed25519 AAAA one",
             "ssh-rsa AAAA two"
           ]

    assert Provisioning.ssh_keys(%{"ssh_authorized_keys" => ""}) == []
    assert Provisioning.ssh_keys(%{}) == []
  end
end
