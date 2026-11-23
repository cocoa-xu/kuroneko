defmodule Kuroneko.USBNetworkTest do
  use ExUnit.Case, async: true

  alias Kuroneko.USBNetwork

  test "an address with its prefix, /24 when there is none" do
    assert USBNetwork.parse("10.55.0.1/24") == {:ok, {10, 55, 0, 1}, 24}
    assert USBNetwork.parse(" 192.168.7.1 ") == {:ok, {192, 168, 7, 1}, 24}
    assert USBNetwork.parse("10.55.0.1/31") == {:error, :invalid_prefix}
    assert USBNetwork.parse("10.55.0.1/x") == {:error, :invalid_address}

    for text <- ["10.55.0", "10.55.0.256/24", "fe80::1/64", "", "a/b/c"] do
      assert USBNetwork.parse(text) == {:error, :invalid_address}, text
    end
  end

  test "the NanoKVM at its address, the computer at the next through DHCP, no router" do
    assert USBNetwork.config("10.55.0.1/24") ==
             {:ok,
              %{
                type: VintageNetEthernet,
                ipv4: %{method: :static, address: {10, 55, 0, 1}, prefix_length: 24},
                dhcpd: %{
                  start: {10, 55, 0, 2},
                  end: {10, 55, 0, 11},
                  options: %{subnet: {255, 255, 255, 0}}
                }
              }}

    assert {:ok, %{dhcpd: %{start: {10, 9, 9, 1}, end: {10, 9, 9, 1}}}} =
             USBNetwork.config("10.9.9.2/30")

    assert {:ok, %{dhcpd: %{start: {10, 9, 9, 2}, end: {10, 9, 9, 2}}}} =
             USBNetwork.config("10.9.9.1/30")

    assert USBNetwork.config(nil) == {:ok, %{type: VintageNetDirect}}
  end

  test "no reserved addresses, no network or broadcast address, no other network's range" do
    for text <- ["127.0.0.1/8", "169.254.3.1/16", "224.0.0.1/24", "0.1.2.3/8"] do
      assert USBNetwork.config(text) == {:error, :reserved_address}, text
    end

    assert USBNetwork.config("10.55.0.0/24") == {:error, :not_a_host}
    assert USBNetwork.config("10.55.0.255/24") == {:error, :not_a_host}
    assert USBNetwork.config("192.168.1.9/24", ["192.168.1.20/24"]) == {:error, :overlaps}
    assert USBNetwork.config("192.168.0.9/16", ["192.168.1.20/24"]) == {:error, :overlaps}
    assert {:ok, _config} = USBNetwork.config("192.168.2.9/24", ["192.168.1.20/24"])
  end

  test "the host has no USB network" do
    assert USBNetwork.current() == %{default: true, address: nil, computer: nil}
    assert USBNetwork.set("10.55.0.1/24") == {:error, :no_network}
  end
end
