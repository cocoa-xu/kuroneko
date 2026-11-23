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

  defp usb_info(settings) do
    %{
      settings: settings,
      endpoints: %{in: 6, out: 2, have: %{in: 7, out: 7}},
      changed: false,
      applying: false
    }
  end

  defp size(canvas) do
    {width, height} = Pages.size()
    assert byte_size(Canvas.render(canvas)) == width * height * 2
  end

  test "every page draws at the size the panel shows" do
    settings = %Settings{calibration: {1.0, 0.0, 0.0, 0.0, 1.0, 0.0}}

    for view <- [
          %{page: :status, info: @status, settings: settings, toast: nil},
          %{page: :status, info: %{@status | wifi: nil, video: :none, temperature: nil}},
          %{
            page: :status,
            info: Map.merge(@status, %{setup_code: "012345", host: "nerves-1234"})
          },
          %{
            page: :status,
            info: Map.merge(@status, %{setup_code: "999999", host: "x", wifi: nil})
          },
          %{page: :network, info: @network, settings: settings, toast: {"Calibrated", :ok}},
          %{page: :network, info: %{@network | ap: nil}},
          %{page: :settings, settings: settings, toast: nil},
          %{page: :usb, info: usb_info(Kuroneko.USBSettings.defaults()), toast: nil},
          %{
            page: :usb,
            info: %{usb_info(Kuroneko.USBSettings.defaults()) | changed: true},
            toast: {"USB devices set", :ok}
          },
          %{
            page: :usb,
            info: %{
              usb_info(%{Kuroneko.USBSettings.defaults() | "audio" => "duplex"})
              | endpoints: %{in: 8, out: 3, have: %{in: 7, out: 7}}
            }
          },
          %{page: :usb, info: %{usb_info(Kuroneko.USBSettings.defaults()) | applying: true}},
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

  test "until there is a password, the status page shows where to set it and the code" do
    info = Map.merge(@status, %{setup_code: "012345", host: "nerves-1234"})
    canvas = Pages.render(%{page: :status, info: info})
    texts = for {:text, _x, _y, text, _color, scale} <- canvas.items, do: {to_string(text), scale}

    assert {"012 345", 3} in texts
    assert {"https://192.0.2.10/", 1} in texts
    assert {"http://nerves-1234.local/", 1} in texts

    without_setup = Pages.render(%{page: :status, info: Map.put(info, :setup_code, nil)})
    refute Enum.any?(without_setup.items, &match?({:text, _, _, ~c"012 345", _, _}, &1))
  end

  test "tiles and buttons are where they are drawn" do
    assert Pages.tile_at({60, 100}) == :brightness
    assert Pages.tile_at({180, 200}) == :touch
    assert Pages.tile_at({120, 100}) == nil
    assert Pages.button_at({120, 80}, false) == :paint
    assert Pages.button_at({120, 210}, false) == nil
    assert Pages.button_at({120, 210}, true) == :reset
    assert Pages.usb_tile_at({60, 80}) == :input
    assert Pages.usb_tile_at({180, 210}) == :apply
    assert Pages.usb_tile_at({120, 150}) == nil
  end

  test "the USB page says what does not fit" do
    info = %{
      settings: Kuroneko.USBSettings.defaults(),
      endpoints: %{in: 8, out: 3, have: %{in: 7, out: 7}},
      changed: true,
      applying: false
    }

    texts =
      for {:text, _x, _y, text, _color, _scale} <- Pages.render(%{page: :usb, info: info}).items,
          do: to_string(text)

    assert "Endpoints IN 8/7 OUT 3/7" in texts
    assert "Full" in texts
    refute "Apply" in texts
  end
end
