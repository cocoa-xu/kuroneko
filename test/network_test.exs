defmodule Kuroneko.NetworkTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Network

  # The host has no VintageNet: no interfaces, and the defaults.
  test "without VintageNet, nothing but the defaults" do
    assert Network.interfaces() == []
    assert Network.get("wlan0", ["connection"]) == nil
    assert Network.get("wlan0", ["addresses"], []) == []
    assert Network.addresses("wlan0") == []
    assert Network.ipv4("usb0") == nil
    assert Network.wifi("wlan0") == nil
  end
end
