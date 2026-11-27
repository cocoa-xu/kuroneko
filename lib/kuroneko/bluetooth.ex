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
  # NanoKVMGo.Bluetooth.HID.

  @spec start_link(atom()) :: {:ok, pid()}
  def start_link(kind), do: {:ok, spawn_link(fn -> loop(kind) end)}

  defp loop(kind) do
    receive do
      {:report, report} -> NanoKVMGo.Bluetooth.HID.report(kind, report)
    end

    loop(kind)
  end
end
