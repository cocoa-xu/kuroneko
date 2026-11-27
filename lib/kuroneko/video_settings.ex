defmodule Kuroneko.VideoSettings do
  @moduledoc """
  How the video stream is encoded, saved across restarts, as
  `NanoKVMGo.Video` takes it (`t:NanoKVMGo.Video.encoding/0`):

    * `"codec"` - `"h264"`, `"h265"` or `"auto"`: H.265 while every viewer
      decodes it, H.264 otherwise
    * `"rate_control"` - `"constant_qp"`, `"cbr"` or `"vbr"`
    * `"bitrate"` - bits a second: what CBR keeps to, the most VBR takes
    * `"qp"` - the quantizer of a constant QP, and the best VBR goes to
    * `"keyframe_interval"` - frames from a keyframe to the next
    * `"max_fps"` - frames a second at most, 0 for the input's
    * `"color_matrix"` - `"auto"`, `"bt601"` or `"bt709"`, and
      `"color_range"` - `"auto"`, `"full"` or `"limited"`: the colour the
      HDMI bridge turns the picture into where the system can convert it
      (`"auto"` keeps the bridge's own, BT.709 at full range), and
      otherwise what the stream says its colour is

  The presets set the first three, as the stock firmware's do: `"auto"`
  (VBR of up to 8 Mbit/s), `"highest"`, `"high"`, `"medium"` and `"low"`
  (CBR of 10, 5, 3 and 1 Mbit/s). Settings are JSON-shaped maps, as the page
  sends them.

  Changes go through this process, one at a time, so that the stream has
  the settings saved. `NanoKVMGo.Video` takes them as it starts, restarts
  too, from `encoding/0`.
  """
  use GenServer

  @presets [
    {"auto", "Auto", %{"rate_control" => "vbr", "bitrate" => 8_000_000, "qp" => 24}},
    {"highest", "Highest", %{"rate_control" => "cbr", "bitrate" => 10_000_000}},
    {"high", "High", %{"rate_control" => "cbr", "bitrate" => 5_000_000}},
    {"medium", "Medium", %{"rate_control" => "cbr", "bitrate" => 3_000_000}},
    {"low", "Low", %{"rate_control" => "cbr", "bitrate" => 1_000_000}}
  ]
  @defaults %{
    "codec" => "auto",
    "rate_control" => "vbr",
    "bitrate" => 8_000_000,
    "qp" => 24,
    "keyframe_interval" => 600,
    "max_fps" => 0,
    "color_matrix" => "auto",
    "color_range" => "auto"
  }
  @codecs %{"auto" => :auto, "h264" => :h264, "h265" => :h265}
  @rate_controls %{"constant_qp" => :constant_qp, "cbr" => :cbr, "vbr" => :vbr}
  @color_matrices %{"auto" => :auto, "bt601" => :bt601, "bt709" => :bt709}
  @color_ranges %{"auto" => :auto, "full" => :full, "limited" => :limited}

  @type t() :: %{String.t() => term()}

  @doc "Starts the process that changes go through."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The saved settings, the defaults for what is not saved."
  @spec saved() :: t()
  def saved do
    with {:ok, json} <- File.read(path()),
         {:ok, changes} when is_map(changes) <- Jason.decode(json),
         {:ok, settings} <- merge(@defaults, changes) do
      settings
    else
      _ -> @defaults
    end
  end

  @doc "The presets, in order: `%{\"name\", \"label\"}` and what each sets."
  @spec presets() :: [map()]
  def presets do
    for {name, label, values} <- @presets,
        do: Map.merge(values, %{"name" => name, "label" => label})
  end

  @doc "The preset the settings are, `\"custom\"` for none."
  @spec preset(t()) :: String.t()
  def preset(settings) do
    Enum.find_value(@presets, "custom", fn {name, _label, values} ->
      if Map.take(settings, Map.keys(values)) == values, do: name
    end)
  end

  @doc "The settings as `NanoKVMGo.Video`'s `:encoding`."
  @spec encoding(t()) :: keyword()
  def encoding(settings) do
    [
      codec: Map.fetch!(@codecs, settings["codec"]),
      rate_control: Map.fetch!(@rate_controls, settings["rate_control"]),
      bitrate: settings["bitrate"],
      qp: settings["qp"],
      keyframe_interval: settings["keyframe_interval"],
      max_fps: settings["max_fps"],
      color_matrix: Map.fetch!(@color_matrices, settings["color_matrix"]),
      color_range: Map.fetch!(@color_ranges, settings["color_range"])
    ]
  end

  @doc "The saved settings as `NanoKVMGo.Video`'s `:encoding`."
  @spec encoding() :: keyword()
  def encoding, do: encoding(saved())

  @doc """
  Applies changes to the saved settings, `"preset"` for a preset's: the
  stream changes from its next frame. `{:error, {:invalid, key}}` for one
  it does not take.
  """
  @spec update(map()) :: {:ok, t()} | {:error, term()}
  def update(changes), do: GenServer.call(__MODULE__, {:update, changes})

  @impl GenServer
  def init(nil), do: {:ok, nil}

  # Saved, then applied: a NanoKVMGo.Video starting meanwhile reads the file
  # once its name is registered, so it reads these settings or gets the call.
  @impl GenServer
  def handle_call({:update, changes}, _from, state) do
    reply =
      with {:ok, settings} <- merge(saved(), changes),
           :ok <- save(settings) do
        :ok = apply_encoding(settings)
        {:ok, settings}
      end

    {:reply, reply, state}
  end

  defp apply_encoding(settings) do
    _encoding = NanoKVMGo.Video.set_encoding(encoding(settings))
    :ok
  catch
    :exit, {:noproc, _call} -> :ok
  end

  defp merge(settings, changes) when is_map(changes) do
    {preset, changes} = Map.pop(changes, "preset")

    with {:ok, settings} <- put_preset(settings, preset) do
      Enum.reduce_while(changes, {:ok, settings}, fn {key, value}, {:ok, acc} ->
        if valid?(key, value),
          do: {:cont, {:ok, Map.put(acc, key, value)}},
          else: {:halt, {:error, {:invalid, key}}}
      end)
    end
  end

  defp merge(_settings, _changes), do: {:error, :not_an_object}

  defp put_preset(settings, nil), do: {:ok, settings}

  defp put_preset(settings, name) do
    case List.keyfind(@presets, name, 0) do
      {^name, _label, values} -> {:ok, Map.merge(settings, values)}
      nil -> {:error, {:invalid, "preset"}}
    end
  end

  defp valid?("codec", codec), do: is_map_key(@codecs, codec)
  defp valid?("rate_control", rate_control), do: is_map_key(@rate_controls, rate_control)
  defp valid?("bitrate", bitrate), do: bitrate in 100_000..50_000_000
  defp valid?("qp", qp), do: qp in 0..51
  defp valid?("keyframe_interval", frames), do: frames in 1..65_535
  defp valid?("max_fps", fps), do: fps in 0..240
  defp valid?("color_matrix", matrix), do: is_map_key(@color_matrices, matrix)
  defp valid?("color_range", range), do: is_map_key(@color_ranges, range)
  defp valid?(_key, _value), do: false

  defp save(settings) do
    with :ok <- File.mkdir_p(Path.dirname(path())) do
      tmp = path() <> ".tmp"
      with :ok <- File.write(tmp, Jason.encode!(settings)), do: File.rename(tmp, path())
    end
  end

  defp path do
    Application.get_env(:kuroneko, :video_settings_file, "/data/kuroneko/video.json")
  end
end
