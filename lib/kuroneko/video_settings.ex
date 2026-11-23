defmodule Kuroneko.VideoSettings do
  @moduledoc """
  How the H.264 stream is encoded, saved across restarts, as
  `NanoKVMGo.Video` takes it (`t:NanoKVMGo.Video.encoding/0`):

    * `"rate_control"` - `"constant_qp"`, `"cbr"` or `"vbr"`
    * `"bitrate"` - bits a second: what CBR keeps to, the most VBR takes
    * `"qp"` - the quantizer of a constant QP, and the best VBR goes to
    * `"keyframe_interval"` - frames from a keyframe to the next
    * `"max_fps"` - frames a second at most, 0 for the input's

  The presets set the first three, as the stock firmware's do: `"auto"`
  (VBR of up to 8 Mbit/s), `"highest"`, `"high"`, `"medium"` and `"low"`
  (CBR of 10, 5, 3 and 1 Mbit/s). Settings are JSON-shaped maps, as the page
  sends them.
  """

  @presets [
    {"auto", "Auto", %{"rate_control" => "vbr", "bitrate" => 8_000_000, "qp" => 24}},
    {"highest", "Highest", %{"rate_control" => "cbr", "bitrate" => 10_000_000}},
    {"high", "High", %{"rate_control" => "cbr", "bitrate" => 5_000_000}},
    {"medium", "Medium", %{"rate_control" => "cbr", "bitrate" => 3_000_000}},
    {"low", "Low", %{"rate_control" => "cbr", "bitrate" => 1_000_000}}
  ]
  @defaults %{
    "rate_control" => "vbr",
    "bitrate" => 8_000_000,
    "qp" => 24,
    "keyframe_interval" => 600,
    "max_fps" => 0
  }
  @rate_controls %{"constant_qp" => :constant_qp, "cbr" => :cbr, "vbr" => :vbr}

  @type t() :: %{String.t() => term()}

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
      rate_control: Map.fetch!(@rate_controls, settings["rate_control"]),
      bitrate: settings["bitrate"],
      qp: settings["qp"],
      keyframe_interval: settings["keyframe_interval"],
      max_fps: settings["max_fps"]
    ]
  end

  @doc """
  Applies changes to the saved settings, `"preset"` for a preset's: the
  stream changes from its next frame. `{:error, {:invalid, key}}` for one
  it does not take.
  """
  @spec update(map()) :: {:ok, t()} | {:error, term()}
  def update(changes) do
    with {:ok, settings} <- merge(saved(), changes),
         :ok <- save(settings) do
      apply_encoding(settings)
      {:ok, settings}
    end
  end

  # NanoKVMGo.Video takes the saved settings when it starts.
  defp apply_encoding(settings) do
    _encoding = NanoKVMGo.Video.set_encoding(encoding(settings))
    :ok
  catch
    :exit, _not_running -> :ok
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

  defp valid?("rate_control", rate_control), do: is_map_key(@rate_controls, rate_control)
  defp valid?("bitrate", bitrate), do: bitrate in 100_000..50_000_000
  defp valid?("qp", qp), do: qp in 0..51
  defp valid?("keyframe_interval", frames), do: frames in 1..65_535
  defp valid?("max_fps", fps), do: fps in 0..240
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
