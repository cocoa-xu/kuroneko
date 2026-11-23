defmodule Kuroneko.Screen.USB do
  @moduledoc """
  The USB devices as the LCD changes them: a tap steps a tile's setting, and
  Apply sets them all at once, so that the target sees its USB devices
  reconnect once (`Kuroneko.USBSettings`).
  """

  @sounds ["off", "mic", "duplex"]
  @drives [1, 2, 3, 4, 8, 16]
  @most 4

  @typedoc "A tile of the USB page that steps a setting."
  @type tile() :: :input | :sound | :drives | :disks | :networks

  @doc """
  Settings with a tile's setting at its next step: the keyboard and mice on
  or off, the sound card's next mode, the virtual disk's drives (1, 2, 3, 4,
  8, 16, then off), or one more storage device or network, none again after
  four. Those a tap adds take names of their own, `"disk2"` and `"usb1"`, and
  one drive.
  """
  @spec step(Kuroneko.USBSettings.t(), tile()) :: Kuroneko.USBSettings.t()
  def step(settings, :input), do: %{settings | "hid" => not settings["hid"]}
  def step(settings, :sound), do: %{settings | "audio" => next(@sounds, settings["audio"])}

  def step(%{"storage" => false} = settings, :drives),
    do: %{settings | "storage" => true, "drives" => 1}

  def step(settings, :drives) do
    case Enum.find(@drives, &(&1 > settings["drives"])) do
      nil -> %{settings | "storage" => false, "drives" => 1}
      drives -> %{settings | "drives" => drives}
    end
  end

  def step(%{"storages" => storages} = settings, :disks) when length(storages) >= @most,
    do: %{settings | "storages" => []}

  def step(%{"storages" => storages} = settings, :disks) do
    name = free_name("disk", ["disk" | Enum.map(storages, & &1["name"])], 2)
    %{settings | "storages" => storages ++ [%{"name" => name, "drives" => 1}]}
  end

  def step(%{"networks" => networks} = settings, :networks) when length(networks) >= @most,
    do: %{settings | "networks" => []}

  def step(%{"networks" => networks} = settings, :networks),
    do: %{settings | "networks" => networks ++ [free_name("usb", ["usb0" | networks], 1)]}

  @doc "What of settings the USB page changes, as `Kuroneko.USBSettings.update/1` takes it."
  @spec changes(Kuroneko.USBSettings.t()) :: map()
  def changes(settings),
    do: Map.take(settings, ["hid", "audio", "storage", "drives", "storages", "networks"])

  defp next(steps, value) do
    case Enum.drop_while(steps, &(&1 != value)) do
      [_value, next | _rest] -> next
      _last_or_unknown -> hd(steps)
    end
  end

  defp free_name(prefix, taken, from) do
    from
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(&"#{prefix}#{&1}")
    |> Enum.find(&(&1 not in taken))
  end
end
