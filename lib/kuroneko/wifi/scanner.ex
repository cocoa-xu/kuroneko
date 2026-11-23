defmodule Kuroneko.WiFi.Scanner do
  @moduledoc """
  The access points in reach, kept as a phone keeps its list: each one for
  five minutes after it was last seen, so that a scan that misses a network
  does not take it off the list, and scanned again on request, at most
  every ten seconds, while the settings page is open.

  VintageNet runs on the device only: on the host the list stays empty.
  """

  use GenServer

  @ifname "wlan0"
  @property ["interface", @ifname, "wifi", "access_points"]
  @keep :timer.minutes(5)
  @interval :timer.seconds(10)

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The access points seen in the last five minutes. With `scan: true`, a
  scan starts when the last one is ten seconds old or more; what it finds
  comes a few seconds later.
  """
  @spec access_points(keyword()) :: [map()]
  def access_points(opts \\ []) do
    GenServer.call(__MODULE__, {:access_points, Keyword.get(opts, :scan, false)})
  catch
    :exit, _reason -> []
  end

  @doc "Scans now; what it finds comes a few seconds later."
  @spec scan() :: :ok | {:error, term()}
  def scan do
    GenServer.call(__MODULE__, :scan)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  @spec remember(map(), [map()], integer()) :: map()
  def remember(seen, access_points, now),
    do: Enum.reduce(access_points, seen, &Map.put(&2, &1.bssid, {&1, now}))

  @doc false
  @spec recent(map(), integer()) :: map()
  def recent(seen, now), do: Map.filter(seen, fn {_bssid, {_ap, at}} -> now - at <= @keep end)

  @doc false
  @spec due?(integer() | nil, integer()) :: boolean()
  def due?(nil, _now), do: true
  def due?(last_scan, now), do: now - last_scan >= @interval

  @impl GenServer
  def init(_opts) do
    seen =
      if vintage_net?() do
        apply(VintageNet, :subscribe, [@property])
        remember(%{}, apply(VintageNet, :get, [@property]) || [], now())
      else
        %{}
      end

    {:ok, %{seen: seen, last_scan: nil}}
  end

  @impl GenServer
  def handle_call({:access_points, scan?}, _from, state) do
    now = now()

    state =
      if scan? and due?(state.last_scan, now),
        do: state |> start_scan(now) |> elem(1),
        else: state

    seen = recent(state.seen, now)
    {:reply, for({_bssid, {ap, _at}} <- seen, do: ap), %{state | seen: seen}}
  end

  def handle_call(:scan, _from, state) do
    {result, state} = start_scan(state, now())
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({VintageNet, @property, _old, access_points, _meta}, state),
    do: {:noreply, %{state | seen: remember(state.seen, access_points || [], now())}}

  defp start_scan(state, now) do
    result =
      try do
        if vintage_net?(), do: apply(VintageNet, :scan, [@ifname]), else: {:error, :no_wifi}
      catch
        # wpa_supplicant not answering must not take the list down.
        :exit, reason -> {:error, reason}
      end

    {result, %{state | last_scan: now}}
  end

  defp now, do: System.monotonic_time(:millisecond)
  defp vintage_net?, do: Code.ensure_loaded?(VintageNet)
end
