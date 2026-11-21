defmodule Kuroneko.Provisioning do
  @moduledoc """
  What the card was burned with (`config/provisioning.conf`), applied at
  boot:

    * `wifi_ssid` and `wifi_passphrase`: the Wi-Fi to join while the device
      has none, or at every boot with `wifi_force`, as Nerves Livebook does
    * `ssh_authorized_keys`: public keys that may log in over SSH, one per
      line, added once and then cleared, so that a key removed on the
      settings page stays removed
  """

  require Logger

  @doc "Applies what the card was burned with."
  @spec run() :: :ok
  def run do
    kv = Nerves.Runtime.KV.get_all()

    with {:join, ssid, passphrase} <- wifi(kv, Kuroneko.WiFi.configured?()),
         {:error, reason} <- Kuroneko.WiFi.join(ssid, passphrase) do
      Logger.error("kuroneko: the card's Wi-Fi not joined: #{inspect(reason)}")
    end

    case ssh_keys(kv) do
      [] ->
        :ok

      keys ->
        Enum.each(keys, &add_key/1)
        Nerves.Runtime.KV.put("ssh_authorized_keys", "")
    end
  end

  @doc """
  What to do about the Wi-Fi: join the card's network while none is
  configured, or always when forced.
  """
  @spec wifi(map(), boolean()) :: {:join, String.t(), String.t() | nil} | :none
  def wifi(kv, configured?) do
    if (true?(kv["wifi_force"]) or not configured?) and not empty?(kv["wifi_ssid"]),
      do: {:join, kv["wifi_ssid"], kv["wifi_passphrase"]},
      else: :none
  end

  @doc "The card's SSH keys, one per line; comments and blank lines left out."
  @spec ssh_keys(map()) :: [String.t()]
  def ssh_keys(kv) do
    (kv["ssh_authorized_keys"] || "")
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  defp add_key(key) do
    with {:error, reason} <- Kuroneko.SSH.add_keys(key) do
      Logger.error("kuroneko: an SSH key from the card not added: #{inspect(reason)}")
    end
  end

  defp true?(value), do: value not in [nil, "", "false", "FALSE"]
  defp empty?(value), do: value in [nil, ""]
end
