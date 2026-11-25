defmodule Kuroneko.VideoSettingsTest do
  use ExUnit.Case, async: false

  alias Kuroneko.VideoSettings

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:kuroneko, :video_settings_file, Path.join(tmp_dir, "video.json"))
    on_exit(fn -> Application.delete_env(:kuroneko, :video_settings_file) end)
  end

  test "VBR of up to 8 Mbit/s at QP 24 until changed, the Auto preset, codec and colour" do
    settings = VideoSettings.saved()
    assert VideoSettings.preset(settings) == "auto"
    assert settings["codec"] == "auto"

    assert VideoSettings.encoding(settings) == [
             codec: :auto,
             rate_control: :vbr,
             bitrate: 8_000_000,
             qp: 24,
             keyframe_interval: 600,
             max_fps: 0,
             color_matrix: :auto,
             color_range: :auto
           ]
  end

  test "a preset sets the rate control, and the rest stays" do
    assert {:ok, _settings} = VideoSettings.update(%{"max_fps" => 30})
    assert {:ok, settings} = VideoSettings.update(%{"preset" => "medium"})

    assert %{"rate_control" => "cbr", "bitrate" => 3_000_000, "max_fps" => 30} = settings
    assert VideoSettings.preset(settings) == "medium"
    assert VideoSettings.saved() == settings

    assert {:ok, settings} = VideoSettings.update(%{"bitrate" => 4_000_000})
    assert VideoSettings.preset(settings) == "custom"
    assert Enum.map(VideoSettings.presets(), & &1["name"]) == ~w(auto highest high medium low)
  end

  test "refuses settings the stream does not take, saving none" do
    for changes <- [
          %{"preset" => "ultra"},
          %{"codec" => "vp9"},
          %{"rate_control" => "abr"},
          %{"bitrate" => 0},
          %{"qp" => 52},
          %{"keyframe_interval" => 0},
          %{"max_fps" => -1},
          %{"color_matrix" => "bt2020"},
          %{"color_range" => "tv"},
          %{"gop" => 30}
        ] do
      assert {:error, {:invalid, _setting}} = VideoSettings.update(changes), inspect(changes)
    end

    assert VideoSettings.preset(VideoSettings.saved()) == "auto"
  end

  test "a saved file that is not settings is the defaults", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "video.json"), ~s({"qp": "best"}))
    assert VideoSettings.preset(VideoSettings.saved()) == "auto"
  end
end
