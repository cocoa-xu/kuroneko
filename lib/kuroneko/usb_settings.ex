defmodule Kuroneko.USBSettings do
  @moduledoc """
  The USB devices the target sees, saved across restarts:

    * `"hid"` - the keyboard and mice
    * `"pointer"` - the absolute pointer: `"absolute"` (a mouse), `"stylus"`
      (a pen, for Android and iPadOS) or `"touch"` (a touch screen); the
      relative mouse is always there with it
    * `"storage"` - the virtual disk
    * `"drives"` - its drives, 1 to 16: the storage function's LUNs, which
      take the endpoints of one
    * `"audio"` - the sound card in the stock firmware's modes: `"off"`,
      `"mic"` (a microphone the browser talks into) and `"duplex"` (also a
      speaker, whose sound the browser plays)
    * `"jiggler"` - whether the mouse moves a pixel and back each minute,
      so that the target does not sleep
    * `"microphone"` and `"speaker"` - the format of each direction:
      `"channels"`, the `"rates"` the target chooses from (starting with the
      first), `"sample_bits"`

  Settings are JSON-shaped maps, as the page sends them.
  """

  @modes %{"off" => [], "mic" => [:microphone], "duplex" => [:microphone, :speaker]}
  # 48 kHz first, which the target starts with, as with the stock firmware.
  @default_format %{"channels" => 2, "rates" => [48_000, 44_100], "sample_bits" => 16}
  @pointers ["absolute", "stylus", "touch"]
  @defaults %{
    "hid" => true,
    "pointer" => "absolute",
    "jiggler" => false,
    "storage" => true,
    "drives" => 1,
    "audio" => "off",
    "microphone" => @default_format,
    "speaker" => @default_format
  }

  @type t() :: %{String.t() => term()}

  @spec defaults() :: t()
  def defaults, do: @defaults

  @spec modes() :: [String.t()]
  def modes, do: ["off", "mic", "duplex"]

  @doc "The saved settings, the defaults for what is not saved."
  @spec saved() :: t()
  def saved do
    with {:ok, json} <- File.read(path()),
         {:ok, changes} when is_map(changes) <- Jason.decode(json),
         {:ok, settings} <- merge(@defaults, changes) do
      settings
    else
      _ -> legacy()
    end
  end

  # The audio mode alone, as the firmware before kept it.
  defp legacy do
    case File.read(Path.join(Path.dirname(path()), "audio_mode")) do
      {:ok, mode} ->
        Map.put(
          @defaults,
          "audio",
          Map.get(%{"mic" => "mic", "duplex" => "duplex"}, String.trim(mode), "off")
        )

      {:error, _reason} ->
        @defaults
    end
  end

  @doc "The `Kuroneko.Gadget` functions of settings."
  @spec functions(t()) :: [Kuroneko.Gadget.function_spec()]
  def functions(settings) do
    hid =
      if settings["hid"],
        do: [:keyboard, {:mouse, mode: pointer_mode(settings["pointer"])}, :relative_mouse],
        else: []

    storage =
      cond do
        not settings["storage"] -> []
        settings["drives"] > 1 -> [{:storage, luns: settings["drives"]}]
        true -> [:storage]
      end

    hid ++ storage ++ Enum.map(@modes[settings["audio"]], &{&1, audio_options(settings, &1)})
  end

  @doc "The sound card mode of the USB functions the gadget has."
  @spec mode([atom()]) :: String.t()
  def mode(functions) do
    Enum.find(["duplex", "mic"], "off", fn mode -> Enum.all?(@modes[mode], &(&1 in functions)) end)
  end

  @doc """
  Merges changes into settings: `{:ok, settings}`, or `{:error, reason}`
  for changes the USB functions cannot take, including formats of a
  direction the sound card does not have yet.
  """
  @spec merge(t(), map()) :: {:ok, t()} | {:error, term()}
  def merge(settings, changes) when is_map(changes) do
    with {:ok, settings} <- put_all(settings, changes),
         :ok <-
           Kuroneko.Gadget.validate(
             Enum.map([:microphone, :speaker], &{&1, audio_options(settings, &1)}),
             NanoKVMGo.USB.gadget_options()
           ) do
      {:ok, settings}
    end
  end

  def merge(_settings, _changes), do: {:error, :not_an_object}

  @doc """
  Applies changes to the saved settings: sets the USB functions up, then
  saves. The target sees the USB devices reconnect when they change.
  """
  @spec update(map()) :: {:ok, t()} | {:error, term()}
  def update(changes) do
    with {:ok, settings} <- merge(saved(), changes),
         :ok <- Kuroneko.Gadget.configure(functions(settings)),
         :ok <- save(settings) do
      Kuroneko.VirtualDisk.drives_changed()
      {:ok, settings}
    end
  end

  defp put_all(settings, changes) do
    Enum.reduce_while(changes, {:ok, settings}, fn {key, value}, {:ok, acc} ->
      case put(acc, key, value) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        :error -> {:halt, {:error, {:invalid, key}}}
      end
    end)
  end

  defp put(settings, key, value) when key in ["hid", "storage", "jiggler"] and is_boolean(value),
    do: {:ok, %{settings | key => value}}

  defp put(settings, "drives", drives) when drives in 1..16,
    do: {:ok, %{settings | "drives" => drives}}

  defp put(settings, "audio", mode) when is_map_key(@modes, mode),
    do: {:ok, %{settings | "audio" => mode}}

  defp put(settings, "pointer", mode) when mode in @pointers,
    do: {:ok, %{settings | "pointer" => mode}}

  defp put(settings, key, format) when key in ["microphone", "speaker"] and is_map(format) do
    format = Map.merge(settings[key], Map.take(format, Map.keys(@default_format)))

    if is_integer(format["channels"]) and is_list(format["rates"]) and
         is_integer(format["sample_bits"]),
       do: {:ok, %{settings | key => format}},
       else: :error
  end

  defp put(_settings, _key, _value), do: :error

  defp pointer_mode("stylus"), do: :stylus
  defp pointer_mode("touch"), do: :touch
  defp pointer_mode(_absolute), do: :absolute

  defp audio_options(settings, direction) do
    format = settings[Atom.to_string(direction)]

    [
      channels: format["channels"],
      rates: format["rates"],
      sample_bits: format["sample_bits"]
    ]
  end

  defp save(settings) do
    with :ok <- File.mkdir_p(Path.dirname(path())) do
      tmp = path() <> ".tmp"

      with :ok <- File.write(tmp, Jason.encode!(settings)), do: File.rename(tmp, path())
    end
  end

  defp path do
    Application.get_env(:kuroneko, :usb_settings_file, "/data/kuroneko/usb.json")
  end
end
