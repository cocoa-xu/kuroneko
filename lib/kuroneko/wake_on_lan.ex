defmodule Kuroneko.WakeOnLan do
  @moduledoc """
  Wake-on-LAN: the magic packet for a MAC address, broadcast on the local
  networks.
  """

  @doc """
  Parses a MAC address: six hex bytes, separated by `:` or `-`.

      iex> Kuroneko.WakeOnLan.parse_mac("AA:bb:cc-01-02-03")
      {:ok, <<0xAA, 0xBB, 0xCC, 1, 2, 3>>}
      iex> Kuroneko.WakeOnLan.parse_mac("AA:BB")
      :error
  """
  @spec parse_mac(String.t()) :: {:ok, <<_::48>>} | :error
  def parse_mac(text) do
    with [_, _, _, _, _, _] = parts <- String.split(text, [":", "-"]),
         {:ok, bytes} <- Base.decode16(Enum.join(parts), case: :mixed),
         6 <- byte_size(bytes) do
      {:ok, bytes}
    else
      _ -> :error
    end
  end

  @doc """
  The magic packet: six 0xFF bytes, then the address sixteen times.
  """
  @spec packet(<<_::48>>) :: binary()
  def packet(<<_::48>> = mac), do: :binary.copy(<<0xFF>>, 6) <> :binary.copy(mac, 16)

  @doc "The MAC address woken last, kept for next time; `\"\"` before any."
  @spec saved_mac() :: String.t()
  def saved_mac do
    case File.read(saved_path()) do
      {:ok, text} -> String.trim(text)
      {:error, _reason} -> ""
    end
  end

  @doc "Keeps a MAC address as the one to wake next time."
  @spec save_mac(String.t()) :: :ok | {:error, term()}
  def save_mac(text) do
    with :ok <- File.mkdir_p(Path.dirname(saved_path())), do: File.write(saved_path(), text)
  end

  defp saved_path, do: Application.get_env(:kuroneko, :wake_file, "/data/kuroneko/wake_mac")

  @doc """
  Broadcasts the magic packet for a MAC address to port 9.
  """
  @spec wake(<<_::48>>) :: :ok | {:error, term()}
  def wake(mac) do
    with {:ok, socket} <- :gen_udp.open(0, [:binary, broadcast: true]) do
      result = :gen_udp.send(socket, {255, 255, 255, 255}, 9, packet(mac))
      :gen_udp.close(socket)
      result
    end
  end
end
