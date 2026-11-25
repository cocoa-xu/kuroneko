defmodule Kuroneko.Network do
  @moduledoc """
  The network interfaces' properties from VintageNet, which runs on the
  device only: on the host there are no interfaces and every property is
  its default.
  """

  @doc "The interfaces, without the loopback."
  @spec interfaces() :: [String.t()]
  def interfaces do
    if vintage_net?(), do: apply(VintageNet, :all_interfaces, []) -- ["lo"], else: []
  end

  @doc """
  A property of an interface, such as `get("wlan0", ["wifi", "current_ap"])`.
  """
  @spec get(String.t(), [String.t()], term()) :: term()
  def get(ifname, key, default \\ nil) do
    if vintage_net?(),
      do: apply(VintageNet, :get, [["interface", ifname | key], default]),
      else: default
  end

  @doc """
  Sends the caller `{VintageNet, ["interface", ifname | key], old, new,
  metadata}` each time the property changes; nothing on the host.
  """
  @spec subscribe(String.t(), [String.t()]) :: :ok
  def subscribe(ifname, key) do
    if vintage_net?(),
      do: apply(VintageNet, :subscribe, [["interface", ifname | key]]),
      else: :ok
  end

  @doc "The addresses of an interface with their prefixes, `\"192.0.2.10/24\"`."
  @spec addresses(String.t()) :: [String.t()]
  def addresses(ifname) do
    for %{address: address, prefix_length: prefix} <- get(ifname, ["addresses"], []),
        do: "#{:inet.ntoa(address)}/#{prefix}"
  end

  @doc """
  The Wi-Fi link of an interface, `nil` while it has none: the network's
  name, the access point's address, the band and channel, the signal in dBm
  and percent and the link speed in Mb/s, polled from wpa_supplicant now.

  VintageNet learns the access point's name only when wpa_supplicant answers
  a query after connecting, which it does not always do; the name is then
  the configured network's, when there is one.
  """
  @spec wifi(String.t()) :: map() | nil
  def wifi(ifname) do
    with true <- vintage_net?(),
         {:ok, %{frequency: frequency} = signal} <-
           apply(VintageNet, :ioctl, [ifname, :signal_poll, []]) do
      ap = get(ifname, ["wifi", "current_ap"])

      %{
        ssid: if(ap, do: ap.ssid, else: configured_ssid(ifname)),
        bssid: ap && ap.bssid,
        frequency: frequency,
        band: band(frequency),
        channel: channel(frequency),
        signal_dbm: signal.signal_dbm,
        signal_percent: signal.signal_percent,
        link_speed: signal.linkspeed,
        width: signal.width
      }
    else
      _ -> nil
    end
  catch
    # wpa_supplicant not answering must not take the caller down.
    :exit, {reason, _call} when reason in [:noproc, :timeout] -> nil
  end

  # Only the name: the configuration holds the passphrase too.
  defp configured_ssid(ifname) do
    case apply(VintageNet, :get_configuration, [ifname]) do
      %{vintage_net_wifi: %{networks: [%{ssid: ssid}]}} -> ssid
      _ -> nil
    end
  end

  @doc "The Wi-Fi band of a frequency in MHz, `\"5 GHz\"`."
  @spec band(integer()) :: String.t() | nil
  def band(mhz) when mhz in 2401..2495, do: "2.4 GHz"
  def band(mhz) when mhz in 5150..5925, do: "5 GHz"
  def band(mhz) when mhz in 5926..7125, do: "6 GHz"
  def band(_mhz), do: nil

  defp channel(2484), do: 14
  defp channel(mhz) when mhz in 2401..2495, do: div(mhz - 2407, 5)
  defp channel(mhz) when mhz in 5150..5925, do: div(mhz - 5000, 5)
  defp channel(mhz) when mhz in 5926..7125, do: div(mhz - 5950, 5)
  defp channel(_mhz), do: nil

  @doc "The first IPv4 address of an interface, without its prefix."
  @spec ipv4(String.t()) :: String.t() | nil
  def ipv4(ifname) do
    Enum.find_value(get(ifname, ["addresses"], []), fn
      %{family: :inet, address: address} -> address |> :inet.ntoa() |> to_string()
      _other -> nil
    end)
  end

  defp vintage_net?, do: Code.ensure_loaded?(VintageNet)
end
