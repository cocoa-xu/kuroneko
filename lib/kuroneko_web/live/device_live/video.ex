defmodule KuronekoWeb.DeviceLive.Video do
  @moduledoc false
  # The video input, and how the stream is encoded: each change applies at
  # once, from the next frame.

  use KuronekoWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kuroneko.VideoSettings
  alias KuronekoWeb.Format

  @bitrates Enum.map([1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20], &(&1 * 1_000_000))
  @qps [16, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 40]
  @keyframes [30, 60, 150, 300, 600, 1200]
  @fps_caps [0, 60, 30, 20, 15, 10, 5]
  @codecs %{"h264" => "H.264", "h265" => "H.265"}

  @doc "The settings, the preset they are, the presets and the stream's codec now."
  def encoding do
    settings = VideoSettings.saved()

    %{
      settings: settings,
      preset: VideoSettings.preset(settings),
      presets: VideoSettings.presets(),
      codec: stream_codec()
    }
  end

  defp stream_codec do
    NanoKVMGo.Video.codec()
  catch
    :exit, _not_running -> nil
  end

  attr :video, :map, required: true
  attr :components, :list, required: true
  attr :encoding, :map, required: true

  def video_card(assigns) do
    input = assigns.video.input
    signal = is_map(input)
    capture = assigns.video[:capture] || %{}
    bridge = Enum.find(assigns.components, &(to_string(&1[:id]) == "video_bridge"))
    s = assigns.encoding.settings
    fps = if signal, do: input.fps

    assigns =
      assign(assigns,
        signal: signal,
        s: s,
        facts: [
          {"Input",
           if(signal,
             do: "#{input.width} × #{input.height}, #{input.fps} FPS",
             else: Format.input(input)
           )},
          {"Bridge", bridge && bridge[:chip]},
          {"Encoders", "H.264, H.265 and JPEG, in the SoC"},
          {"Input changes", capture[:mid_frame_stops] && to_string(capture.mid_frame_stops)},
          {"Receiver restarts", capture[:csi_recoveries] && to_string(capture.csi_recoveries)}
        ],
        now:
          [
            assigns.encoding.codec && "Now #{@codecs[to_string(assigns.encoding.codec)]}",
            assigns.encoding.preset == "custom" && "custom quality"
          ]
          |> Enum.filter(& &1)
          |> Enum.join(", "),
        bitrates: with_current(@bitrates, s["bitrate"]),
        qps: with_current(@qps, s["qp"]),
        keyframes: with_current(@keyframes, s["keyframe_interval"]),
        fps_caps: with_current(@fps_caps, s["max_fps"]),
        fps: fps
      )

    ~H"""
    <.card id="video" title="Video input" icon="hero-tv">
      <:actions>
        <.badge kind={
          if @signal, do: :ok, else: if(@video.input in [:unsupported, "unsupported"], do: :bad)
        }>
          {if @signal, do: "Signal", else: Format.input(@video.input)}
        </.badge>
      </:actions>
      <.facts rows={@facts} />

      <.section title="Video stream">
        <:actions>
          <span class="text-xs text-base-content/55">{@now}</span>
        </:actions>
        <.group>
          <.row label="Codec">
            <.segmented
              label="Codec"
              event="video:codec"
              value={@s["codec"]}
              options={[{"auto", "Auto"}, {"h264", "H.264"}, {"h265", "H.265"}]}
            />
          </.row>
          <.row label="Preset">
            <.segmented
              label="Preset"
              event="video:preset"
              value={@encoding.preset}
              options={Enum.map(@encoding.presets, &{&1["name"], &1["label"]})}
              class="flex-wrap"
            />
          </.row>
          <.row label="Rate control">
            <.segmented
              label="Rate control"
              event="video:rate_control"
              value={@s["rate_control"]}
              options={[{"vbr", "VBR"}, {"cbr", "CBR"}, {"constant_qp", "Constant QP"}]}
            />
          </.row>
          <.row label="Bitrate">
            <.select
              name="bitrate"
              event="video:bitrate"
              value={@s["bitrate"]}
              disabled={@s["rate_control"] == "constant_qp"}
              options={
                Enum.map(
                  @bitrates,
                  &{&1, if(@s["rate_control"] == "cbr", do: mbit(&1), else: "Up to #{mbit(&1)}")}
                )
              }
            />
          </.row>
          <.row label="Quality">
            <.select
              name="qp"
              event="video:qp"
              value={@s["qp"]}
              disabled={@s["rate_control"] == "cbr"}
              options={Enum.map(@qps, &{&1, qp_label(&1)})}
            />
          </.row>
          <.row label="Keyframes">
            <.select
              name="keyframe_interval"
              event="video:keyframe_interval"
              value={@s["keyframe_interval"]}
              options={Enum.map(@keyframes, &{&1, keyframe_label(&1, @fps)})}
            />
          </.row>
          <.row label="Frame rate">
            <.select
              name="max_fps"
              event="video:max_fps"
              value={@s["max_fps"]}
              options={
                Enum.map(@fps_caps, &{&1, if(&1 == 0, do: "As the input", else: "At most #{&1} FPS")})
              }
            />
          </.row>
          <.row label="Colour">
            <.segmented
              label="Colour"
              event="video:color_matrix"
              value={@s["color_matrix"]}
              options={[{"auto", "Auto"}, {"bt709", "BT.709"}, {"bt601", "BT.601"}]}
            />
          </.row>
          <.row label="Range">
            <.segmented
              label="Range"
              event="video:color_range"
              value={@s["color_range"]}
              options={[{"auto", "Auto"}, {"full", "Full"}, {"limited", "Limited"}]}
            />
          </.row>
        </.group>

        <p class="mt-4 text-xs text-base-content/55">
          Auto streams H.265 when every viewer's browser decodes it, H.264 otherwise; H.265 needs about half the
          bitrate for the same picture. VBR keeps the quality, a QP, and takes a higher QP only where the bitrate
          would go over its most; CBR keeps to the bitrate; a constant QP takes what each frame needs.
        </p>
        <p class="mt-2 text-xs text-base-content/55">
          The HDMI bridge converts the picture to the colour chosen; Auto keeps its own, BT.709 at full range.
          Browsers decode the MJPEG view as BT.601, so BT.709 leaves its strongest colours a little off there;
          H.264 and H.265 tell the browser which they carry.
        </p>
      </.section>
    </.card>
    """
  end

  attr :name, :string, required: true
  attr :event, :string, required: true
  attr :value, :any, required: true
  attr :options, :list, required: true
  attr :disabled, :boolean, default: false

  defp select(assigns) do
    ~H"""
    <form id={"video-#{@name}"} phx-change={@event} phx-auto-recover="ignore">
      <select name={@name} class="select select-sm w-56" disabled={@disabled}>
        <option :for={{value, label} <- @options} value={value} selected={value == @value}>
          {label}
        </option>
      </select>
    </form>
    """
  end

  defp with_current(values, nil), do: values

  defp with_current(values, current),
    do: if(current in values, do: values, else: Enum.sort([current | values]))

  defp mbit(bps), do: "#{trim(Float.round(bps / 1_000_000, 1))} Mbit/s"
  defp trim(f), do: if(f == trunc(f), do: trunc(f), else: f)

  defp qp_label(qp) when qp <= 18, do: "QP #{qp}, the finest"
  defp qp_label(qp) when qp >= 36, do: "QP #{qp}, the smallest"
  defp qp_label(qp), do: "QP #{qp}"

  defp keyframe_label(frames, nil), do: "Every #{frames} frames"

  defp keyframe_label(frames, fps),
    do: "Every #{frames} frames, #{trim(Float.round(frames / fps, 1))} s"

  @segments %{
    "codec" => %{"auto" => "The codec every viewer decodes", "h264" => "H.264", "h265" => "H.265"},
    "rate_control" => %{"vbr" => "VBR", "cbr" => "CBR", "constant_qp" => "Constant QP"},
    "color_matrix" => %{
      "auto" => "Colour: Auto",
      "bt709" => "Colour: BT.709",
      "bt601" => "Colour: BT.601"
    },
    "color_range" => %{
      "auto" => "Range: Auto",
      "full" => "Range: Full",
      "limited" => "Range: Limited"
    }
  }

  def event("preset", %{"value" => preset}, socket),
    do: change(socket, %{"preset" => preset}, "#{String.capitalize(preset)} quality")

  def event(setting, %{"value" => value}, socket) when is_map_key(@segments, setting),
    do: change(socket, %{setting => value}, @segments[setting][value])

  def event(setting, params, socket) when setting in ~w(bitrate qp keyframe_interval max_fps),
    do: change(socket, %{setting => String.to_integer(params[setting])}, nil)

  defp change(socket, changes, done) do
    case VideoSettings.update(changes) do
      {:ok, _settings} ->
        socket = assign(socket, encoding: encoding())
        {:noreply, if(done, do: put_flash(socket, :info, done), else: socket)}

      {:error, {:invalid, setting}} ->
        {:noreply,
         put_flash(socket, :error, "Video stream: the NanoKVM does not take that #{setting}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Video stream: #{inspect(reason)}")}
    end
  end
end
