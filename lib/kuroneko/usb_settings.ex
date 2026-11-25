defmodule Kuroneko.USBSettings do
  @moduledoc """
  The USB devices the target sees, saved across restarts:

    * `"hid"` - the keyboard and mice
    * `"pointer"` - the absolute pointer: `"absolute"` (a mouse), `"stylus"`
      (a pen, for Android and iPadOS) or `"touch"` (a touch screen); the
      relative mouse is always there with it
    * `"network"` - the system's USB network, `usb0`
    * `"networks"` - USB networks besides the system's, by name:
      `["usb1"]`; the kernel names their interfaces
      (`Kuroneko.Gadget.instances/1`), VintageNetDirect gives them addresses
      (`Kuroneko.USBNetwork.configure_more/0`)
    * `"storage"` - the virtual disk
    * `"drives"` - its drives, 1 to 16: the storage function's LUNs, which
      take the endpoints of one
    * `"storages"` - more storage devices, each a USB device with its own
      drives: `[%{"name" => "boot", "drives" => 1}]`
    * `"audio"` - the sound card in the stock firmware's modes: `"off"`,
      `"mic"` (a microphone the browser talks into) and `"duplex"` (also a
      speaker, whose sound the browser plays)
    * `"jiggler"` - whether the mouse moves a pixel and back each minute,
      so that the target does not sleep
    * `"microphone"` and `"speaker"` - the format of each direction:
      `"channels"`, the `"rates"` the target chooses from (starting with the
      first), `"sample_bits"`

  Settings are JSON-shaped maps, as the page sends them. The functions must
  fit the device controller's endpoints (`Kuroneko.Gadget.endpoints/1`).

  Changes go through this process, one at a time, so that the gadget has
  the settings saved. `Kuroneko.Gadget` takes them as it starts, restarts
  too, from `functions/0`.
  """
  use GenServer

  @modes %{"off" => [], "mic" => [:microphone], "duplex" => [:microphone, :speaker]}
  # 48 kHz first, which the target starts with, as with the stock firmware.
  @default_format %{"channels" => 2, "rates" => [48_000, 44_100], "sample_bits" => 16}
  @pointers ["absolute", "stylus", "touch"]
  @defaults %{
    "hid" => true,
    "pointer" => "absolute",
    "jiggler" => false,
    "network" => true,
    "networks" => [],
    "storage" => true,
    "drives" => 1,
    "storages" => [],
    "audio" => "off",
    "microphone" => @default_format,
    "speaker" => @default_format
  }

  @type t() :: %{String.t() => term()}

  @doc "Starts the process that changes go through."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

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

  @doc "The `Kuroneko.Gadget` functions of the saved settings."
  @spec functions() :: [Kuroneko.Gadget.function_spec()]
  def functions, do: functions(saved())

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

    storage =
      storage ++
        for %{"name" => name, "drives" => luns} <- settings["storages"],
            do: {:storage, name: name, luns: luns}

    networks =
      if(settings["network"], do: [{:network, name: "usb0"}], else: []) ++
        for(name <- settings["networks"], do: {:network, name: name})

    networks ++
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
    gadget = board()

    with {:ok, settings} <- put_all(settings, changes),
         :ok <-
           Kuroneko.Gadget.validate(
             Enum.map([:microphone, :speaker], &{&1, audio_options(settings, &1)}),
             gadget
           ),
         :ok <- Kuroneko.Gadget.validate(functions(settings), gadget) do
      {:ok, settings}
    end
  end

  def merge(_settings, _changes), do: {:error, :not_an_object}

  @doc """
  The endpoints the USB functions of settings take, and those the device
  has: `%{in: 7, out: 3, have: %{in: 7, out: 7}}`.
  """
  @spec endpoints(t()) :: %{
          in: non_neg_integer(),
          out: non_neg_integer(),
          have: %{in: non_neg_integer(), out: non_neg_integer()} | nil
        }
  def endpoints(settings) do
    {:ok, use} = Kuroneko.Gadget.endpoints(functions(settings))
    Map.put(use, :have, board()[:endpoints])
  end

  # What the functions are checked against. The serial number only makes the
  # network's addresses: without it, no boardid runs at every check.
  defp board, do: NanoKVMGo.USB.gadget_options(serial_number: nil)

  @doc """
  Applies changes to the saved settings and sets the USB functions up. The
  target sees the USB devices reconnect when they change.
  """
  @spec update(map()) :: {:ok, t()} | {:error, term()}
  def update(changes), do: GenServer.call(__MODULE__, {:update, changes}, 60_000)

  @impl GenServer
  def init(nil), do: {:ok, nil}

  # Checked, saved, then set up: a gadget restarting meanwhile starts with
  # them. A refusal leaves the gadget as it was, and the saved settings too.
  @impl GenServer
  def handle_call({:update, changes}, _from, state) do
    saved = saved()

    reply =
      with {:ok, settings} <- merge(saved, changes),
           :ok <- Kuroneko.Gadget.validate(functions(settings), board()),
           :ok <- save(settings),
           :ok <- configure(settings, saved) do
        {:ok, settings}
      end

    {:reply, reply, state}
  end

  defp configure(settings, saved) do
    case Kuroneko.Gadget.configure(functions(settings)) do
      :ok ->
        Kuroneko.VirtualDisk.drives_changed()
        Kuroneko.USBNetwork.configure_more()

      {:error, _reason} = error ->
        :ok = save(saved)
        error
    end
  catch
    :exit, {:noproc, _call} -> :ok
  end

  defp put_all(settings, changes) do
    Enum.reduce_while(changes, {:ok, settings}, fn {key, value}, {:ok, acc} ->
      case put(acc, key, value) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        :error -> {:halt, {:error, {:invalid, key}}}
      end
    end)
  end

  defp put(settings, "networks", names) when is_list(names) do
    if Enum.all?(names, &name?/1) and names == Enum.uniq(names) and "usb0" not in names and
         length(names) <= 4,
       do: {:ok, %{settings | "networks" => names}},
       else: :error
  end

  defp put(settings, "storages", storages) when is_list(storages) do
    names = Enum.map(storages, &(is_map(&1) && &1["name"]))

    valid =
      Enum.all?(storages, fn storage ->
        is_map(storage) and name?(storage["name"]) and storage["drives"] in 1..16 and
          map_size(storage) == 2
      end)

    if valid and names == Enum.uniq(names) and "disk" not in names and length(storages) <= 4,
      do: {:ok, %{settings | "storages" => storages}},
      else: :error
  end

  defp put(settings, key, value)
       when key in ["hid", "storage", "jiggler", "network"] and is_boolean(value),
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

  # A function's name in configfs: letters, digits, "_" and "-".
  defp name?(name),
    do: is_binary(name) and byte_size(name) in 1..32 and String.match?(name, ~r/^[A-Za-z0-9_-]+$/)

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
