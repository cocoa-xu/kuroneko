defmodule Kuroneko.Bluetooth do
  @moduledoc """
  The KVM's keyboard and mouse over Bluetooth: the board as a Bluetooth LE
  keyboard and mouse, for a phone, tablet or computer that pairs with it.

  `Kuroneko.Bluetooth.Input`, a `Kuroneko.Gadget.Input` of its own, drives
  it with the same reports as the USB devices, the keyboard, the absolute
  pointer and the relative mouse in one report map. The viewer page sends
  its input there or to USB (`Kuroneko.InputSocket`).

  It needs BlueZ in the system: without bluetoothd nothing starts.
  """

  alias Kuroneko.Gadget.HID

  @reports [keyboard: 1, mouse: 2, relative_mouse: 3]
  # GAP appearance: a keyboard
  @appearance 0x03C1

  @doc "Whether the system has BlueZ."
  @spec available?() :: boolean()
  def available?, do: File.exists?("/usr/libexec/bluetooth/bluetoothd")

  @doc "The processes, for a `:rest_for_one` supervisor; none without BlueZ."
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children do
    if available?() do
      [
        {NanoKVMGo.Bluetooth, name: name()},
        {NanoKVMGo.Bluetooth.HID,
         report_map: report_map(),
         inputs: for({kind, id} <- @reports, do: {kind, {id, report_length(kind)}}),
         outputs: [leds: {@reports[:keyboard], 1}],
         appearance: @appearance,
         local_name: name()},
        {Kuroneko.Gadget.Input,
         [name: __MODULE__.Input, pointer_mode: :absolute] ++
           for({kind, _id} <- @reports, do: {kind, {__MODULE__.Writer, kind}})}
      ]
    else
      []
    end
  end

  @doc """
  The name others see: Kuroneko and the end of the host name, `Kuroneko
  f186` for `nerves-f186`, short enough for an advertisement.
  """
  @spec name() :: String.t()
  def name do
    {:ok, host} = :inet.gethostname()

    "Kuroneko " <>
      (host |> to_string() |> String.split("-") |> List.last() |> String.slice(-4, 4))
  end

  @doc "For the pages: the controller, the paired devices and whether a host listens."
  @spec status() :: map() | nil
  def status do
    with true <- available?(),
         {:ok, info} <- NanoKVMGo.Bluetooth.info() do
      %{
        name: info.name,
        address: info.address,
        pairing: info.pairing,
        host: NanoKVMGo.Bluetooth.HID.connected?(),
        devices:
          for(
            device <- NanoKVMGo.Bluetooth.devices(),
            device.paired,
            do: Map.take(device, [:address, :name, :icon, :connected])
          )
      }
    else
      _off -> nil
    end
  catch
    :exit, _not_running -> nil
  end

  # One report map: each USB device's descriptor with its report ID.
  defp report_map do
    for {kind, id} <- @reports, into: <<>> do
      kind
      |> HID.descriptor()
      |> Map.fetch!(:report_desc)
      |> NanoKVMGo.Bluetooth.HID.with_report_id(id)
    end
  end

  defp report_length(kind), do: HID.descriptor(kind).report_length
end

defmodule Kuroneko.Bluetooth.Writer do
  @moduledoc false
  # Hands the reports Kuroneko.Bluetooth.Input makes for one device to
  # NanoKVMGo.Bluetooth.HID. iOS moves its pointer by the absolute mouse but
  # takes buttons and wheels from the relative one only: the absolute
  # mouse's go there, where the pointer is, which on hosts of one pointer
  # comes to the same.
  #
  # Movement goes at most once a connection interval. The page moves the
  # mouse faster than LE carries notifications, and a queue in bluetoothd
  # would leave the pointer further behind the longer it moves: a position
  # not sent yet gives way to a newer one, relative steps add up. Buttons
  # and wheels go at once, after the movement before them.

  alias NanoKVMGo.Bluetooth.HID

  # The connection interval BlueZ asks hosts for (main.conf's [LE]).
  @interval_ms 15

  @spec start_link(atom()) :: {:ok, pid()}
  def start_link(:mouse),
    do:
      {:ok,
       spawn_link(fn -> pointer(%{position: nil, sent: nil, buttons: 0, at: nil, due: false}) end)}

  def start_link(:relative_mouse),
    do: {:ok, spawn_link(fn -> relative(%{dx: 0, dy: 0, buttons: 0, at: nil, due: false}) end)}

  def start_link(kind), do: {:ok, spawn_link(fn -> loop(kind) end)}

  defp loop(kind) do
    receive do
      {:report, report} -> HID.report(kind, report)
    end

    loop(kind)
  end

  defp pointer(state) do
    receive do
      {:report, <<buttons, x::little-16, y::little-16, wheel, pan>>} ->
        state = %{state | position: {x, y}}

        if buttons != state.buttons or wheel != 0 or pan != 0 do
          state = send_position(state)
          HID.report(:relative_mouse, <<buttons, 0, 0, wheel, pan>>)
          pointer(%{state | buttons: buttons})
        else
          pointer(pace(state, &send_position/1))
        end

      :due ->
        pointer(send_position(%{state | due: false}))
    end
  end

  defp send_position(%{position: nil} = state), do: state
  defp send_position(%{position: same, sent: same} = state), do: %{state | position: nil}

  defp send_position(%{position: {x, y}} = state) do
    HID.report(:mouse, <<0, x::little-16, y::little-16, 0, 0>>)
    %{state | position: nil, sent: {x, y}, at: now()}
  end

  defp relative(state) do
    receive do
      {:report, <<buttons, dx::signed, dy::signed, wheel::signed, pan::signed>>} ->
        state = %{state | dx: state.dx + dx, dy: state.dy + dy}

        if buttons != state.buttons or wheel != 0 or pan != 0 do
          state = send_steps(state)
          HID.report(:relative_mouse, <<buttons, 0, 0, wheel::signed, pan::signed>>)
          relative(%{state | buttons: buttons})
        else
          relative(pace(state, &send_steps/1))
        end

      :due ->
        relative(send_steps(%{state | due: false}))
    end
  end

  # What added up, in steps of at most 127 each way.
  defp send_steps(%{dx: 0, dy: 0} = state), do: state

  defp send_steps(state) do
    {dx, dy} = {clamp(state.dx), clamp(state.dy)}
    HID.report(:relative_mouse, <<state.buttons, dx::signed, dy::signed, 0, 0>>)
    send_steps(%{state | dx: state.dx - dx, dy: state.dy - dy, at: now()})
  end

  # At once when an interval has passed since the last movement went, else
  # once it has.
  defp pace(%{due: true} = state, _send), do: state

  defp pace(state, send) do
    wait = if state.at, do: state.at + @interval_ms - now(), else: 0

    if wait > 0 do
      Process.send_after(self(), :due, wait)
      %{state | due: true}
    else
      send.(state)
    end
  end

  defp clamp(n), do: n |> max(-127) |> min(127)
  defp now, do: System.monotonic_time(:millisecond)
end
