defmodule Kuroneko.Screen.PagesTest do
  use ExUnit.Case, async: true

  alias NanoKVMGo.Display.Canvas
  alias Kuroneko.Screen.{Pages, Settings}

  @status %{
    wifi: "192.0.2.10",
    usb: nil,
    video: %{width: 1920, height: 1080, fps: 60},
    sound: "mic",
    input: true,
    temperature: 51.3
  }
  @network %{
    host: "nerves-1234",
    ap: %{ssid: "example", signal_percent: 80, signal_dbm: -52},
    wifi: "192.0.2.10",
    mac: "aa:bb:cc:dd:ee:ff",
    usb: "172.31.36.97"
  }
  @stats %{
    cpu: %{total: 37.5, cores: [20.0, 55.0]},
    memory: %{used: 120_000_000, total: 380_000_000, percent: 31.6},
    network: %{"wlan0" => %{down: 1_234_567.0, up: 45_000.0}, "usb0" => %{down: 12.0, up: 0.0}}
  }
  @about %{
    version: "0.1.0",
    firmware: "0.1.0",
    uuid: "bf01b650-1234",
    kernel: "7.3.0",
    uptime: 93_784
  }

  defp size(canvas) do
    {width, height} = Pages.size()
    assert byte_size(Canvas.render(canvas)) == width * height * 2
  end

  test "every page draws at the size the panel shows" do
    settings = %Settings{calibration: {1.0, 0.0, 0.0, 0.0, 1.0, 0.0}}

    for view <- [
          %{page: :status, info: @status, settings: settings, toast: nil},
          %{page: :status, info: %{@status | wifi: nil, video: :none, temperature: nil}},
          %{page: :network, info: @network, settings: settings, toast: {"Calibrated", :ok}},
          %{page: :network, info: %{@network | ap: nil}},
          %{page: :settings, settings: settings, toast: nil},
          %{page: :touch, settings: settings, toast: {"Missed a cross", :error}},
          %{page: :touch, settings: %Settings{}},
          %{page: :about, info: @about},
          %{page: :system, info: %{stats: nil, history: nil}},
          %{page: :system, info: %{stats: @stats, history: %{cpu: [5.0, 50.0, 100.0]}}},
          %{page: :system, info: %{stats: %{@stats | network: %{}}, history: nil}},
          %{page: :paint},
          %{
            page: :calibrate,
            step: 4,
            targets: [{40, 60}, {200, 60}, {120, 140}, {40, 220}, {120, 140}]
          }
        ] do
      size(Pages.render(view))
    end
  end

  test "tiles and buttons are where they are drawn" do
    assert Pages.tile_at({60, 100}) == :brightness
    assert Pages.tile_at({180, 200}) == :touch
    assert Pages.tile_at({120, 100}) == nil
    assert Pages.button_at({120, 80}, false) == :paint
    assert Pages.button_at({120, 210}, false) == nil
    assert Pages.button_at({120, 210}, true) == :reset
  end
end
