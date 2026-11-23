defmodule Kuroneko.USBNetwork do
  @moduledoc """
  The USB network's IP addresses.

  By default they are VintageNetDirect's: a /30 in 172.31.0.0/16 made from
  the NanoKVM's name, the NanoKVM at its first address and the computer at
  the second, through DHCP. Where that range is taken, the NanoKVM can sit at
  an address of your own, `"10.55.0.1/24"`, and the computer gets the next
  one through DHCP. Either way the computer gets no router or DNS server: its
  own network stays its way out.

  VintageNet runs on the device only: on the host there is no USB network.
  """

  import Bitwise

  @ifname "usb0"
  # The computer's one address, leased for two minutes: after its MAC address
  # changes, the old lease is gone soon enough for the new one to get it.
  @lease_seconds 120

  @doc """
  The NanoKVM's address with its prefix, the computer's, and whether they
  are the default: `%{default: true, address: "172.31.138.73/30", computer:
  "172.31.138.74"}`. The addresses are `nil` while the network is down.
  """
  @spec current() :: map()
  def current do
    case vintage_net(:get_configuration, [@ifname]) do
      %{ipv4: %{method: :static, address: address, prefix_length: prefix}} ->
        %{
          default: false,
          address: "#{ntoa(address)}/#{prefix}",
          computer: ntoa(computer(address, prefix))
        }

      _direct ->
        case Enum.find(Kuroneko.Network.addresses(@ifname), &String.contains?(&1, ".")) do
          nil ->
            %{default: true, address: nil, computer: nil}

          cidr ->
            {:ok, address, prefix} = parse(cidr)
            %{default: true, address: cidr, computer: ntoa(computer(address, prefix))}
        end
    end
  end

  @doc """
  The configuration that puts the NanoKVM at `cidr`, or at the default for
  `nil`. Checks the address, and that it is not in a network another
  interface is on (`others`, `["192.168.1.20/24"]`).
  """
  @spec config(String.t() | nil, [String.t()]) :: {:ok, map()} | {:error, atom()}
  def config(cidr, others \\ [])

  def config(nil, _others), do: {:ok, %{type: VintageNetDirect}}

  def config(cidr, others) do
    with {:ok, address, prefix} <- parse(cidr),
         :ok <- usable(address, prefix),
         :ok <- apart(address, prefix, others) do
      peer = computer(address, prefix)
      lease = Base.encode16(<<@lease_seconds::32>>)

      {:ok,
       %{
         type: VintageNetEthernet,
         ipv4: %{method: :static, address: address, prefix_length: prefix},
         dhcpd: %{
           start: peer,
           end: peer,
           max_leases: 1,
           # 51: the lease time
           options: %{:subnet => mask(prefix), 51 => lease}
         }
       }}
    end
  end

  @doc "Puts the NanoKVM at `cidr`, or back at the default for `nil`."
  @spec set(String.t() | nil) :: :ok | {:error, term()}
  def set(cidr) do
    with {:ok, config} <- config(cidr, other_networks()) do
      vintage_net(:configure, [@ifname, config])
    end
  end

  @doc "Checks an address as `set/1` would, without setting it."
  @spec check(String.t() | nil) :: :ok | {:error, atom()}
  def check(cidr) do
    with {:ok, _config} <- config(cidr, other_networks()), do: :ok
  end

  @doc false
  @spec parse(String.t()) :: {:ok, :inet.ip4_address(), 8..30} | {:error, atom()}
  def parse(cidr) when is_binary(cidr) do
    {text, prefix} =
      case String.split(String.trim(cidr), "/") do
        [text] -> {text, "24"}
        [text, prefix] -> {text, prefix}
        _other -> {"", ""}
      end

    with {:ok, address} <- :inet.parse_ipv4strict_address(String.to_charlist(text)),
         {prefix, ""} when prefix in 8..30 <- Integer.parse(prefix) do
      {:ok, address, prefix}
    else
      {_prefix, ""} -> {:error, :invalid_prefix}
      _ -> {:error, :invalid_address}
    end
  end

  def parse(_cidr), do: {:error, :invalid_address}

  @doc false
  # The computer's address: the next one, or the one before when the
  # NanoKVM's is the last in its network.
  @spec computer(:inet.ip4_address(), 8..30) :: :inet.ip4_address()
  def computer(address, prefix) do
    next = to_int(address) + 1

    if next < to_int(broadcast(address, prefix)),
      do: from_int(next),
      else: from_int(to_int(address) - 1)
  end

  defp usable({a, b, _c, _d} = address, prefix) do
    cond do
      a in [0, 127] or a >= 224 ->
        {:error, :reserved_address}

      a == 169 and b == 254 ->
        {:error, :reserved_address}

      address == network(address, prefix) or address == broadcast(address, prefix) ->
        {:error, :not_a_host}

      true ->
        :ok
    end
  end

  defp apart(address, prefix, others) do
    overlaps? =
      Enum.any?(others, fn cidr ->
        case parse(cidr) do
          {:ok, other, other_prefix} ->
            shorter = min(prefix, other_prefix)
            network(address, shorter) == network(other, shorter)

          _error ->
            false
        end
      end)

    if overlaps?, do: {:error, :overlaps}, else: :ok
  end

  defp other_networks do
    for ifname <- Kuroneko.Network.interfaces(),
        ifname != @ifname,
        cidr <- Kuroneko.Network.addresses(ifname),
        String.contains?(cidr, "."),
        do: cidr
  end

  defp mask(prefix), do: from_int(bnot((1 <<< (32 - prefix)) - 1) &&& 0xFFFFFFFF)
  defp network(address, prefix), do: from_int(to_int(address) &&& to_int(mask(prefix)))

  defp broadcast(address, prefix),
    do: from_int(to_int(network(address, prefix)) ||| (1 <<< (32 - prefix)) - 1)

  defp to_int({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  defp from_int(n), do: {n >>> 24 &&& 255, n >>> 16 &&& 255, n >>> 8 &&& 255, n &&& 255}
  defp ntoa(address), do: address |> :inet.ntoa() |> to_string()

  defp vintage_net(function, args) do
    if Code.ensure_loaded?(VintageNet),
      do: apply(VintageNet, function, args),
      else: {:error, :no_network}
  end
end
