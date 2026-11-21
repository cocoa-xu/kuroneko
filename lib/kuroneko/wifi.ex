defmodule Kuroneko.WiFi do
  @moduledoc """
  The device's Wi-Fi for the settings page: its state, the networks in
  reach, joining one and forgetting it. The security follows from the
  passphrase: with one, WPA2 or WPA3, whichever the network offers
  (`VintageNetWiFi.Cookbook.generic/2`); without one, an open network.

  VintageNet runs on the device only: on the host there is no Wi-Fi.
  """

  alias Kuroneko.Network

  @ifname "wlan0"

  @doc "Whether the device has a network to join."
  @spec configured?() :: boolean()
  def configured?, do: configured_ssid() != nil

  @doc "The state and the networks in reach, for the page."
  @spec overview() :: map()
  def overview do
    %{
      present: Network.get(@ifname, ["present"], false),
      network: configured_ssid(),
      connection: Network.get(@ifname, ["connection"], :disconnected),
      address: Network.ipv4(@ifname),
      link: Network.wifi(@ifname),
      networks: networks(Network.get(@ifname, ["wifi", "access_points"], []))
    }
  end

  @doc "Looks for networks; they come in `overview/0` a few seconds later."
  @spec scan() :: :ok | {:error, term()}
  def scan, do: vintage_net(:scan, [@ifname])

  @doc """
  The configuration that joins a network, checked: `hidden: true` for one
  that does not announce its name.
  """
  @spec config(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, atom()}
  def config(ssid, passphrase, opts \\ []) when is_binary(ssid) do
    result =
      if passphrase in [nil, ""],
        do: cookbook(:open_wifi, [ssid]),
        else: cookbook(:generic, [ssid, passphrase])

    with {:ok, config} <- result do
      {:ok, if(opts[:hidden], do: scan_for(config), else: config)}
    end
  end

  @doc "Joins a network, from now on and after restarts."
  @spec join(String.t(), String.t() | nil, keyword()) :: :ok | {:error, term()}
  def join(ssid, passphrase, opts \\ []) do
    with {:ok, config} <- config(ssid, passphrase, opts), do: apply_config(config)
  end

  @doc "Applies a configuration that `config/3` made."
  @spec apply_config(map()) :: :ok | {:error, term()}
  def apply_config(config), do: vintage_net(:configure, [@ifname, config])

  @doc "Forgets the network: the device stays off Wi-Fi until it joins another."
  @spec forget() :: :ok | {:error, term()}
  def forget, do: apply_config(%{type: VintageNetWiFi})

  @doc """
  The networks in reach, one per name with its strongest access point, the
  strongest first; hidden ones left out. `security` is `:open`,
  `:personal` (a passphrase), `:enterprise` (a user name too) or `:wep`.
  """
  @spec networks([map()]) :: [map()]
  def networks(access_points) do
    access_points
    |> Enum.reject(&(&1.ssid in [nil, ""]))
    |> Enum.group_by(& &1.ssid)
    |> Enum.map(fn {ssid, aps} ->
      ap = Enum.max_by(aps, & &1.signal_percent)

      %{
        ssid: ssid,
        signal_percent: ap.signal_percent,
        band: Network.band(ap.frequency),
        security: security(ap.flags)
      }
    end)
    |> Enum.sort_by(&{-&1.signal_percent, &1.ssid})
  end

  defp security(flags) do
    names = Enum.map(flags, &Atom.to_string/1)

    cond do
      Enum.any?(names, &String.contains?(&1, "eap")) -> :enterprise
      Enum.any?(names, &String.contains?(&1, ["psk", "sae"])) -> :personal
      "wep" in names -> :wep
      true -> :open
    end
  end

  # A hidden network answers only probes that name it.
  defp scan_for(%{vintage_net_wifi: %{networks: networks}} = config) do
    put_in(config.vintage_net_wifi.networks, Enum.map(networks, &Map.put(&1, :scan_ssid, 1)))
  end

  # Only the name: the configuration holds the passphrase too.
  defp configured_ssid do
    case vintage_net(:get_configuration, [@ifname]) do
      %{vintage_net_wifi: %{networks: [%{ssid: ssid} | _]}} -> ssid
      _ -> nil
    end
  end

  defp cookbook(recipe, args) do
    if Code.ensure_loaded?(VintageNetWiFi.Cookbook),
      do: apply(VintageNetWiFi.Cookbook, recipe, args),
      else: {:error, :no_wifi}
  end

  defp vintage_net(function, args) do
    if Code.ensure_loaded?(VintageNet),
      do: apply(VintageNet, function, args),
      else: {:error, :no_wifi}
  end
end
