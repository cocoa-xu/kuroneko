defmodule Kuroneko.WiFi do
  @moduledoc """
  The device's Wi-Fi for the settings page: its state, the networks in
  reach, joining one and forgetting it.

  A network without a passphrase is open. With one, the device takes WPA2,
  also on networks that offer WPA2 and WPA3, and WPA3 (SAE) only on networks
  that offer nothing else: SAE through this Wi-Fi chip's driver is not
  proven yet. A passphrase of 64 hex digits is the key itself, for WPA2.

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
  The configuration that joins a network, checked. Options: `hidden: true`
  for one that does not announce its name, `:security` as `networks/1`
  gives it, else taken from the networks in reach.
  """
  @spec config(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, atom()}
  def config(ssid, passphrase, opts \\ []) when is_binary(ssid) do
    security = Keyword.get_lazy(opts, :security, fn -> security_of(ssid) end)

    result =
      case recipe(passphrase, security) do
        :open -> cookbook(:open_wifi, [ssid])
        :wpa2 -> cookbook(:wpa_psk, [ssid, passphrase])
        :wpa2_key -> wpa2_key(ssid, passphrase)
        :wpa3 -> cookbook(:generic, [ssid, passphrase])
      end

    with {:ok, config} <- result do
      {:ok, if(opts[:hidden], do: scan_for(config), else: config)}
    end
  end

  @doc "How to join a network with a passphrase and the security it offers."
  @spec recipe(String.t() | nil, atom() | nil) :: :open | :wpa2 | :wpa2_key | :wpa3
  def recipe(passphrase, security) do
    cond do
      passphrase in [nil, ""] -> :open
      passphrase =~ ~r/^[[:xdigit:]]{64}$/ -> :wpa2_key
      security == :wpa3 -> :wpa3
      true -> :wpa2
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
  strongest first; hidden ones left out. `security` is `:open`, `:wpa2`,
  `:wpa2_wpa3`, `:wpa3`, `:enterprise` (a user name too) or `:wep`.
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
    psk? = Enum.any?(names, &String.contains?(&1, "psk"))
    sae? = Enum.any?(names, &String.contains?(&1, "sae"))

    cond do
      Enum.any?(names, &String.contains?(&1, "eap")) -> :enterprise
      psk? and sae? -> :wpa2_wpa3
      sae? -> :wpa3
      psk? -> :wpa2
      "wep" in names -> :wep
      true -> :open
    end
  end

  defp security_of(ssid) do
    Network.get(@ifname, ["wifi", "access_points"], [])
    |> networks()
    |> Enum.find_value(&(&1.ssid == ssid and &1.security))
  end

  # The recipes check passphrases, not keys.
  defp wpa2_key(ssid, key) when byte_size(ssid) in 1..32 do
    network = %{key_mgmt: :wpa_psk, ssid: ssid, psk: key}

    {:ok,
     %{type: VintageNetWiFi, vintage_net_wifi: %{networks: [network]}, ipv4: %{method: :dhcp}}}
  end

  defp wpa2_key("", _key), do: {:error, :ssid_too_short}
  defp wpa2_key(_ssid, _key), do: {:error, :ssid_too_long}

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
