defmodule Kuroneko.Screen.Pages do
  @moduledoc """
  What the LCD shows, as 240 × 270 pictures (the rows the panel shows), and
  where the tiles and buttons to touch are.

  Touches land well in the middle of the panel and poorly at its edges, so
  what is to be touched is big and away from them.
  """

  alias NanoKVMGo.Display.Canvas

  @width 240
  @height 270
  @title_height 44
  @pages [:status, :system, :network, :settings, :about]

  @black Canvas.rgb(0, 0, 0)
  @white Canvas.rgb(255, 255, 255)
  @grey Canvas.rgb(140, 146, 154)
  @dim Canvas.rgb(80, 85, 92)
  @panel Canvas.rgb(34, 38, 44)
  @accent Canvas.rgb(0, 96, 176)
  @green Canvas.rgb(63, 164, 91)
  @red Canvas.rgb(200, 70, 60)
  @yellow Canvas.rgb(230, 190, 60)

  @tiles [
    brightness: {8, 54, 108, 96},
    sleep: {124, 54, 108, 96},
    rotate: {8, 158, 108, 96},
    touch: {124, 158, 108, 96}
  ]

  @buttons [
    paint: {8, 54, 224, 58},
    calibrate: {8, 120, 224, 58},
    reset: {8, 186, 224, 58}
  ]

  @typedoc """
  What to draw: a page with the settings, what it shows (`:info`) and a
  message (`:toast`); the paint test; or the calibration at a step.
  """
  @type view() :: map()

  @doc "The pages a swipe turns, in order."
  @spec pages() :: [atom()]
  def pages, do: @pages

  @doc "The size of the pictures."
  @spec size() :: {pos_integer(), pos_integer()}
  def size, do: {@width, @height}

  @doc "The settings tile at a point, if any."
  @spec tile_at({integer(), integer()}) :: atom() | nil
  def tile_at(point), do: find(@tiles, point)

  @doc "The touch page's button at a point, if any: reset only with a calibration."
  @spec button_at({integer(), integer()}, boolean()) :: atom() | nil
  def button_at(point, calibrated), do: find(buttons(calibrated), point)

  @doc "The picture of a view."
  @spec render(view()) :: Canvas.t()
  def render(%{page: :paint}) do
    Canvas.new(@width, @height, @black)
    |> center(6, "Paint test", @grey)
    |> center(24, "BOOT: done", @dim)
  end

  def render(%{page: :calibrate, step: step, targets: targets}) do
    {x, y} = Enum.at(targets, step)

    Canvas.new(@width, @height, @black)
    |> center(168, "Touch the cross", @white)
    |> center(186, "#{step + 1} of #{length(targets)}", @grey)
    |> center(246, "BOOT: cancel", @dim)
    |> Canvas.rect(x - 12, y, 25, 1, @white)
    |> Canvas.rect(x, y - 12, 1, 25, @white)
    |> Canvas.rect(x - 2, y - 2, 5, 5, @red)
  end

  def render(%{page: :status, info: info} = view) do
    title(:status, "NanoKVM-Go")
    |> lines([
      {"Wi-Fi", info.wifi || "not connected", if(info.wifi, do: @white, else: @grey)},
      {"USB", info.usb || "not connected", if(info.usb, do: @white, else: @grey)},
      video(info.video),
      {"Sound", sound(info.sound), @white},
      {"Input", if(info.input, do: "keyboard, mouse", else: "off"), @white},
      temperature(info.temperature)
    ])
    |> center(240, url(info), @green)
    |> toast(view)
  end

  def render(%{page: :system, info: %{stats: nil}} = view) do
    title(:system, "System")
    |> center(120, "Measuring...", @grey)
    |> toast(view)
  end

  def render(%{page: :system, info: %{stats: stats, history: history}} = view) do
    %{cpu: cpu, memory: memory, network: network} = stats
    cores = "cores " <> Enum.map_join(cpu.cores, " ", &"#{round(&1)}")

    title(:system, "System")
    |> Canvas.text(8, 52, "CPU", @grey)
    |> Canvas.text(80, 52, "#{round(cpu.total)}%", @white)
    |> Canvas.text(@width - 8 - Canvas.text_width(cores, 1), 52, cores, @dim)
    |> bar(70, cpu.total)
    |> Canvas.text(8, 84, "Memory", @grey)
    |> Canvas.text(80, 84, "#{mib(memory.used)} of #{mib(memory.total)} MB", @white)
    |> bar(102, memory.percent)
    |> traffic(116, "Wi-Fi", network["wlan0"])
    |> traffic(154, "USB", network["usb0"])
    |> history(history && history.cpu)
    |> toast(view)
  end

  def render(%{page: :network, info: info} = view) do
    ap = info.ap

    title(:network, "Network")
    |> lines([
      {"Name", info.host, @white},
      {"Wi-Fi", (ap && (ap.ssid || "connected")) || "not connected",
       if(ap, do: @white, else: @grey)},
      {"Signal", if(ap, do: "#{ap.signal_percent}% #{ap.signal_dbm} dBm", else: "-"), @white},
      {"Address", info.wifi || "-", @white},
      {"MAC", info.mac || "-", @white},
      {"USB", info.usb || "-", @white}
    ])
    |> center(240, "#{info.host}.local", @grey)
    |> toast(view)
  end

  def render(%{page: :settings, settings: settings} = view) do
    title(:settings, "Settings")
    |> tile(:brightness, "Brightness", "#{settings.brightness}%", "tap: +20%")
    |> tile(:sleep, "Screen off", sleep(settings.sleep), "tap: longer")
    |> tile(:rotate, "Rotation", "#{settings.rotate}", "tap to turn")
    |> tile(:touch, "Touch panel", "Test", "+ calibrate")
    |> toast(view)
  end

  def render(%{page: :touch, settings: settings} = view) do
    calibrated = settings.calibration != nil

    title(:touch, "Touch panel")
    |> button(:paint, "Paint test", "Draws where you touch")
    |> button(:calibrate, "Calibrate", "Touch five crosses")
    |> then(fn canvas ->
      if calibrated,
        do: button(canvas, :reset, "Reset calibration", "Back to the default"),
        else: center(canvas, 206, "Not calibrated", @grey)
    end)
    |> center(252, "< swipe right: back", @dim)
    |> toast(view)
  end

  def render(%{page: :about, info: info} = view) do
    title(:about, "About")
    |> lines([
      {"App", info.version, @white},
      {"Firmware", info.firmware || "-", @white},
      {"UUID", String.slice(info.uuid || "-", 0, 18), @white},
      {"Linux", info.kernel || "-", @white},
      {"Uptime", uptime(info.uptime), @white},
      {"Board", "NanoKVM-Go", @white}
    ])
    |> toast(view)
  end

  defp buttons(true), do: @buttons
  defp buttons(false), do: Keyword.delete(@buttons, :reset)

  defp find(areas, {x, y}) do
    Enum.find_value(areas, fn {key, {left, top, width, height}} ->
      if x >= left and x < left + width and y >= top and y < top + height, do: key
    end)
  end

  defp title(page, text) do
    Canvas.new(@width, @height, @black)
    |> Canvas.rect(0, 0, @width, @title_height, @accent)
    |> Canvas.text(x_centered(text, 2), 4, text, @white, scale: 2)
    |> dots(page)
  end

  # Where the page is among those a swipe turns; the touch page is under
  # settings, out of the turn.
  defp dots(canvas, :touch), do: canvas

  defp dots(canvas, page) do
    left = div(@width - (length(@pages) * 12 - 4), 2)

    @pages
    |> Enum.with_index()
    |> Enum.reduce(canvas, fn {p, i}, canvas ->
      x = left + i * 12
      Canvas.rect(canvas, x, 37, 8, 3, if(p == page, do: @white, else: @grey))
    end)
  end

  defp lines(canvas, lines) do
    lines
    |> Enum.with_index()
    |> Enum.reduce(canvas, fn {{label, value, color}, i}, canvas ->
      y = 54 + i * 30

      canvas
      |> Canvas.text(8, y, label, @grey)
      |> Canvas.text(80, y, String.slice(value, 0, 20), color)
    end)
  end

  defp tile(canvas, key, label, value, hint) do
    {x, y, width, height} = @tiles[key]

    canvas
    |> Canvas.rect(x, y, width, height, @panel)
    |> Canvas.text(x + div(width - Canvas.text_width(label, 1), 2), y + 8, label, @grey)
    |> Canvas.text(x + div(width - Canvas.text_width(value, 2), 2), y + 34, value, @white,
      scale: 2
    )
    |> Canvas.text(x + div(width - Canvas.text_width(hint, 1), 2), y + 72, hint, @dim)
  end

  defp button(canvas, key, label, hint) do
    {x, y, width, height} = @buttons[key]

    canvas
    |> Canvas.rect(x, y, width, height, @panel)
    |> Canvas.text(x + 12, y + 10, label, @white)
    |> Canvas.text(x + 12, y + 32, hint, @grey)
  end

  # A message over the title, clear of what can be touched.
  defp toast(canvas, %{toast: {text, kind}}) do
    canvas
    |> Canvas.rect(0, 0, @width, @title_height, if(kind == :ok, do: @green, else: @red))
    |> center(14, text, @white)
  end

  defp toast(canvas, _view), do: canvas

  defp center(canvas, y, text, color),
    do: Canvas.text(canvas, x_centered(text, 1), y, text, color)

  defp x_centered(text, scale), do: max(div(@width - Canvas.text_width(text, scale), 2), 0)

  # A share in percent, green to red as it fills.
  defp bar(canvas, y, percent) do
    width = round(224 * min(max(percent, 0), 100) / 100)
    color = if percent >= 85, do: @red, else: if(percent >= 60, do: @yellow, else: @green)

    canvas
    |> Canvas.rect(8, y, 224, 8, @panel)
    |> Canvas.rect(8, y, width, 8, color)
  end

  defp traffic(canvas, y, label, nil) do
    canvas
    |> Canvas.text(8, y, label, @grey)
    |> Canvas.text(80, y, "-", @grey)
  end

  defp traffic(canvas, y, label, %{down: down, up: up}) do
    canvas
    |> Canvas.text(8, y, label, @grey)
    |> Canvas.text(80, y, "down " <> rate(down), @white)
    |> Canvas.text(80, y + 18, "up   " <> rate(up), @white)
  end

  # The last minute of CPU use, a column a second, the newest on the right.
  defp history(canvas, nil), do: canvas

  defp history(canvas, samples) do
    {left, bottom, height} = {8, 256, 58}
    shown = Enum.take(samples, -56)
    offset = 56 - length(shown)

    canvas
    |> Canvas.rect(left, bottom - height, 224, height, @panel)
    |> Canvas.text(left + 4, bottom - height + 2, "CPU, last minute", @dim)
    |> then(fn canvas ->
      shown
      |> Enum.with_index(offset)
      |> Enum.reduce(canvas, fn {percent, i}, canvas ->
        # Under the label at 100 %.
        h = max(round((height - 18) * min(percent, 100) / 100), 1)
        Canvas.rect(canvas, left + i * 4, bottom - h, 3, h, @accent)
      end)
    end)
  end

  defp rate(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB/s"
  defp rate(bytes) when bytes >= 1_000, do: "#{round(bytes / 1_000)} kB/s"
  defp rate(bytes), do: "#{round(bytes)} B/s"

  defp mib(bytes), do: div(bytes, 1_048_576)

  defp video(%{width: w, height: h, fps: fps}), do: {"Video", "#{w}x#{h} #{fps} Hz", @white}
  defp video(:none), do: {"Video", "no signal", @red}
  defp video(:unsupported), do: {"Video", "unsupported input", @red}
  defp video(_starting), do: {"Video", "starting", @grey}

  defp temperature(celsius) when is_number(celsius) do
    color = if celsius >= 80, do: @yellow, else: @white
    {"Temp", "#{:erlang.float_to_binary(celsius / 1, decimals: 1)} C", color}
  end

  defp temperature(_unknown), do: {"Temp", "-", @grey}

  defp url(%{wifi: wifi, usb: usb}) when is_binary(wifi) or is_binary(usb),
    do: "https://#{wifi || usb}/"

  defp url(_info), do: ""

  defp sound("off"), do: "off"
  defp sound("mic"), do: "microphone"
  defp sound("duplex"), do: "mic + speaker"
  defp sound(other), do: to_string(other)

  defp sleep(0), do: "Never"
  defp sleep(minutes) when minutes < 60, do: "#{minutes} min"
  defp sleep(minutes), do: "#{div(minutes, 60)} h"

  defp uptime(seconds) when is_integer(seconds) do
    {days, rest} = {div(seconds, 86_400), rem(seconds, 86_400)}
    {hours, minutes} = {div(rest, 3600), div(rem(rest, 3600), 60)}

    if days > 0,
      do: "#{days} d #{hours} h #{minutes} min",
      else: "#{hours} h #{minutes} min"
  end

  defp uptime(_unknown), do: "-"
end
