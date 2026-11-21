defmodule Kuroneko.Screen do
  @moduledoc """
  The NanoKVM-Go's LCD and its touch panel.

    * pages of status, system (CPU, memory, network, refreshed each
      second), network, settings and about: a swipe left or right turns
      them, so does a tap on a page without tiles
    * settings on big tiles: brightness, screen off after a while, rotation,
      and the touch panel's paint test and calibration
    * the BOOT button turns the backlight off and on, and ends the paint
      test or the calibration; a touch on the dark screen lights it

  The panel shows 270 of its 284 rows and feels touches well in its middle,
  poorly at its edges. The settings are kept in
  `/data/kuroneko/screen.json`; `settings/0` and `update/1` give them
  to the web page.
  """
  use GenServer

  alias NanoKVMGo.{Backlight, Display}
  alias NanoKVMGo.Display.Canvas
  alias Kuroneko.Network
  alias Kuroneko.Screen.{Calibration, Gesture, Pages, Settings}

  @refresh_ms 2_000
  @subscribe_retry_ms 1_000
  @system_refresh_ms 1_000
  @toast_ms 3_000
  @paint_idle_ms 30_000
  @brightness_steps [20, 40, 60, 80, 100]
  @sleep_steps [0, 1, 5, 15, 60]
  @targets [{40, 60}, {200, 60}, {200, 220}, {40, 220}, {120, 140}]
  @paint_colors [
    Canvas.rgb(230, 190, 60),
    Canvas.rgb(63, 164, 91),
    Canvas.rgb(80, 160, 230),
    Canvas.rgb(220, 90, 160),
    Canvas.rgb(240, 240, 240)
  ]
  @dot 7
  {width, height} = Pages.size()
  @width width
  @height height
  # The rows the panel hides, under those it shows.
  @hidden :binary.copy(<<0::16>>, width * 14)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The settings, as JSON takes them, and `pwm_default`: the backlight's PWM
  frequency in Hz when `pwm_frequency` is `nil`, from the device tree.
  """
  @spec settings() :: {:ok, map()} | {:error, :no_screen}
  def settings, do: call(:settings)

  @doc """
  Changes settings (see `check/1`) and answers as `settings/0` does.
  """
  @spec update(map()) :: {:ok, map()} | {:error, term()}
  def update(changes) do
    with :ok <- check(changes), do: call({:update, changes})
  end

  @doc """
  Whether changes from the web page fit: `rotate` 0 or 180, `brightness` 5
  to 100, `sleep` 0 to 1440 minutes, `pwm_frequency` 1 to 1 000 000 Hz or
  `nil`, `calibration` only `nil`, to reset it; the calibration itself is
  made on the screen.
  """
  @spec check(term()) :: :ok | {:error, {:invalid, String.t()} | :not_an_object}
  def check(changes) when is_map(changes) do
    calibration = Map.get(changes, "calibration", Map.get(changes, :calibration))

    with {:ok, _settings} <- Settings.merge(%Settings{}, changes) do
      if calibration == nil, do: :ok, else: {:error, {:invalid, "calibration"}}
    end
  end

  def check(_changes), do: {:error, :not_an_object}

  defp call(request) do
    if GenServer.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, request),
      else: {:error, :no_screen}
  end

  @impl GenServer
  def init(opts) do
    path = Keyword.get(opts, :path, "/data/kuroneko/screen.json")
    settings = Settings.load(path)
    _ = Backlight.set_frequency(settings.pwm_frequency || :default)
    _ = Backlight.set_brightness(settings.brightness)
    _ = Backlight.on()
    send(self(), :refresh)

    state = %{
      path: path,
      settings: settings,
      page: :status,
      mode: :pages,
      lit: true,
      press: nil,
      toast: nil,
      active_at: now(),
      subscriptions: %{}
    }

    {:ok, state |> subscribe(NanoKVMGo.Touch) |> subscribe(NanoKVMGo.Button)}
  end

  @impl GenServer
  def handle_call(:settings, _from, state), do: {:reply, {:ok, settings_map(state)}, state}

  def handle_call({:update, changes}, _from, state) do
    case change_settings(state, changes) do
      {:ok, state} -> {:reply, {:ok, settings_map(state)}, draw(state)}
      error -> {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    Process.send_after(self(), :refresh, refresh_ms(state))
    {:noreply, state |> expire() |> draw()}
  end

  def handle_info({NanoKVMGo.Touch, event}, state),
    do: {:noreply, touch(event, %{state | active_at: now()})}

  def handle_info({NanoKVMGo.Button, :up}, state),
    do: {:noreply, boot_button(%{state | active_at: now()})}

  def handle_info({:subscribe, server}, state), do: {:noreply, subscribe(state, server)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.subscriptions, ref) do
      {nil, _subscriptions} ->
        {:noreply, state}

      {server, subscriptions} ->
        {:noreply, subscribe(%{state | subscriptions: subscriptions}, server)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Touch and Button forget their subscribers when they restart: watch them
  # and subscribe again, retrying until they are back.
  defp subscribe(state, server) do
    with pid when is_pid(pid) <- GenServer.whereis(server),
         ref = Process.monitor(pid),
         :ok <- call_subscribe(server, pid) do
      %{state | subscriptions: Map.put(state.subscriptions, ref, server)}
    else
      _gone ->
        Process.send_after(self(), {:subscribe, server}, @subscribe_retry_ms)
        state
    end
  end

  defp call_subscribe(server, pid) do
    server.subscribe(pid)
  catch
    :exit, reason -> {:error, reason}
  end

  ## Touches

  # The first touch on the dark screen only lights it.
  defp touch({:down, _x, _y}, %{lit: false} = state), do: %{wake(state) | press: :wake}
  defp touch({:up, _x, _y}, %{press: :wake} = state), do: %{state | press: nil}
  defp touch(_event, %{press: :wake} = state), do: state
  defp touch(event, %{mode: {:paint, _at, _stroke}} = state), do: paint(event, state)

  defp touch(event, %{mode: {:calibrate, _step, _samples, _pairs}} = state),
    do: calibrate(event, state)

  defp touch({:down, x, y}, state) do
    point = point(state, x, y)
    %{state | press: {point, point}}
  end

  defp touch({:move, x, y}, %{press: {from, _to}} = state),
    do: %{state | press: {from, point(state, x, y)}}

  defp touch({:up, x, y}, %{press: {from, _to}} = state),
    do: gesture(Gesture.classify(from, point(state, x, y)), %{state | press: nil})

  defp touch(_event, state), do: state

  defp gesture({:swipe, :left}, state), do: turn(state, 1)

  defp gesture({:swipe, :right}, %{page: :touch} = state),
    do: draw(%{state | page: :settings, toast: nil})

  defp gesture({:swipe, :right}, state), do: turn(state, -1)
  defp gesture({:tap, point}, %{page: :settings} = state), do: tile(Pages.tile_at(point), state)

  defp gesture({:tap, point}, %{page: :touch} = state),
    do: touch_button(Pages.button_at(point, state.settings.calibration != nil), state)

  defp gesture({:tap, _point}, state), do: turn(state, 1)
  defp gesture(_gesture, state), do: state

  defp turn(%{page: :touch} = state, _step), do: state

  defp turn(state, step) do
    pages = Pages.pages()
    index = Enum.find_index(pages, &(&1 == state.page))

    draw(%{
      state
      | page: Enum.at(pages, rem(index + step + length(pages), length(pages))),
        toast: nil
    })
  end

  defp tile(:brightness, state),
    do: change(state, %{brightness: next(@brightness_steps, state.settings.brightness)})

  defp tile(:sleep, state), do: change(state, %{sleep: next(@sleep_steps, state.settings.sleep)})
  defp tile(:rotate, state), do: change(state, %{rotate: 180 - state.settings.rotate})
  defp tile(:touch, state), do: draw(%{state | page: :touch, toast: nil})
  defp tile(nil, state), do: state

  # The paint test's page is shown once; the dots go on it.
  defp touch_button(:paint, state) do
    state = %{state | mode: {:paint, now(), 0}, toast: nil}
    _ = Display.show(picture(state))
    state
  end

  defp touch_button(:calibrate, state),
    do: draw(%{state | mode: {:calibrate, 0, [], []}, toast: nil})

  defp touch_button(:reset, state) do
    case change_settings(state, %{calibration: nil}) do
      {:ok, state} -> draw(toast(state, "Calibration reset", :ok))
      {:error, _reason} -> state
    end
  end

  defp touch_button(nil, state), do: state

  # The step after a value, back to the first after the last.
  defp next(steps, value), do: Enum.find(steps, hd(steps), &(&1 > value))

  ## Paint test

  defp paint({:up, _x, _y}, state), do: state

  defp paint({kind, x, y}, %{mode: {:paint, _at, stroke}} = state) do
    stroke = if kind == :down, do: stroke + 1, else: stroke
    {px, py} = physical(state.settings.rotate, point(state, x, y))
    color = Enum.at(@paint_colors, rem(stroke, length(@paint_colors)))
    _ = Display.fill(px - div(@dot, 2), py - div(@dot, 2), @dot, @dot, color)
    %{state | mode: {:paint, now(), stroke}}
  end

  ## Calibration

  defp calibrate({kind, x, y}, %{mode: {:calibrate, step, samples, pairs}} = state)
       when kind in [:down, :move],
       do: %{state | mode: {:calibrate, step, [{x, y} | samples], pairs}}

  defp calibrate({:up, x, y}, %{mode: {:calibrate, step, samples, pairs}} = state) do
    pairs = [
      {average([{x, y} | samples]), physical(state.settings.rotate, Enum.at(@targets, step))}
      | pairs
    ]

    if step + 1 < length(@targets),
      do: draw(%{state | mode: {:calibrate, step + 1, [], pairs}}),
      else: finish_calibration(%{state | mode: :pages, page: :touch}, pairs)
  end

  defp finish_calibration(state, pairs) do
    with {:ok, calibration} <- Calibration.fit(pairs),
         {:ok, state} <- change_settings(state, %{calibration: Tuple.to_list(calibration)}) do
      draw(toast(state, "Calibrated", :ok))
    else
      _error -> draw(toast(state, "Missed a cross: try again", :error))
    end
  end

  defp average(points) do
    {xs, ys} = Enum.unzip(points)
    {Enum.sum(xs) / length(xs), Enum.sum(ys) / length(ys)}
  end

  ## BOOT button and the backlight

  defp boot_button(%{lit: false} = state), do: wake(state)
  defp boot_button(%{mode: :pages} = state), do: dark(state)
  defp boot_button(state), do: draw(%{state | mode: :pages, page: :touch})

  defp refresh_ms(%{page: :system, mode: :pages}), do: @system_refresh_ms
  defp refresh_ms(_state), do: @refresh_ms

  defp wake(state) do
    _ = Backlight.on()
    draw(%{state | lit: true, active_at: now()})
  end

  defp dark(state) do
    _ = Backlight.off()
    %{state | lit: false, press: nil}
  end

  defp expire(state) do
    state
    |> then(fn state -> if expired?(state.toast), do: %{state | toast: nil}, else: state end)
    |> then(fn
      %{mode: {:paint, at, _stroke}} = state when is_integer(at) ->
        if now() - at > @paint_idle_ms,
          do: %{state | mode: :pages, page: :touch},
          else: state

      state ->
        state
    end)
    |> sleep_when_idle()
  end

  defp expired?({_text, _kind, until}), do: now() > until
  defp expired?(nil), do: false

  defp sleep_when_idle(%{lit: true, settings: %{sleep: minutes}} = state) when minutes > 0 do
    if now() - state.active_at >= minutes * 60_000, do: dark(state), else: state
  end

  defp sleep_when_idle(state), do: state

  ## Settings

  defp change(state, changes) do
    case change_settings(state, changes) do
      {:ok, state} -> draw(state)
      {:error, _reason} -> state
    end
  end

  defp change_settings(state, changes) do
    with {:ok, settings} <- Settings.merge(state.settings, changes),
         :ok <- change_pwm(state.settings.pwm_frequency, settings.pwm_frequency) do
      _ =
        if settings.brightness != state.settings.brightness,
          do: Backlight.set_brightness(settings.brightness)

      _ = Settings.save(settings, state.path)
      {:ok, %{state | settings: settings}}
    end
  end

  defp change_pwm(same, same), do: :ok
  defp change_pwm(_old, hz), do: Backlight.set_frequency(hz || :default)

  defp settings_map(state) do
    default =
      case Backlight.info() do
        {:ok, %{default_period: period}} when is_integer(period) -> round(1.0e9 / period)
        _unknown -> nil
      end

    state.settings |> Settings.to_map() |> Map.put(:pwm_default, default)
  end

  defp toast(state, text, kind), do: %{state | toast: {text, kind, now() + @toast_ms}}

  ## Drawing

  # The display writes only the rows that changed, and puts back what else
  # drew over them: showing the picture at each refresh costs little.
  defp draw(%{lit: false} = state), do: state
  defp draw(%{mode: {:paint, _at, _stroke}} = state), do: state

  defp draw(state) do
    _ = Display.show(picture(state))
    state
  end

  defp picture(state),
    do: Canvas.render(Pages.render(view(state)), rotate: state.settings.rotate) <> @hidden

  defp view(%{mode: {:paint, _at, _stroke}}), do: %{page: :paint}

  defp view(%{mode: {:calibrate, step, _samples, _pairs}}),
    do: %{page: :calibrate, step: step, targets: @targets}

  defp view(state) do
    toast = with {text, kind, _until} <- state.toast, do: {text, kind}
    %{page: state.page, settings: state.settings, toast: toast, info: info(state.page)}
  end

  ## Where a touch is

  # A point of the panel, on the picture the way it is turned.
  defp point(state, x, y) do
    calibration = state.settings.calibration || Calibration.default()
    {px, py} = Calibration.to_display(calibration, {x, y})
    physical(state.settings.rotate, {clamp(px, @width), clamp(py, @height)})
  end

  # The same both ways: turning by 180 degrees twice is not turning.
  defp physical(0, point), do: point
  defp physical(180, {x, y}), do: {@width - 1 - x, @height - 1 - y}

  defp clamp(value, size), do: value |> max(0) |> min(size - 1)

  ## What the pages show

  defp info(:status) do
    functions = Kuroneko.Gadget.functions()
    {:ok, host} = :inet.gethostname()

    %{
      setup_code: Kuroneko.SetupCode.current(),
      host: to_string(host),
      wifi: Network.ipv4("wlan0"),
      usb: Network.ipv4("usb0"),
      video: video(),
      sound: Kuroneko.USBSettings.mode(functions),
      input: :keyboard in functions,
      temperature:
        case NanoKVMGo.temperature() do
          {:ok, celsius} -> celsius
          {:error, _reason} -> nil
        end
    }
  end

  defp info(:network) do
    {:ok, host} = :inet.gethostname()

    %{
      host: to_string(host),
      ap: Network.wifi("wlan0"),
      wifi: Network.ipv4("wlan0"),
      mac: Network.get("wlan0", ["mac_address"]),
      usb: Network.ipv4("usb0")
    }
  end

  defp info(:about) do
    {uptime_ms, _since} = :erlang.statistics(:wall_clock)

    %{
      version: to_string(Application.spec(:kuroneko, :vsn)),
      firmware: Nerves.Runtime.KV.get_active("nerves_fw_version"),
      uuid: Nerves.Runtime.KV.get_active("nerves_fw_uuid"),
      kernel:
        case File.read("/proc/sys/kernel/osrelease") do
          {:ok, release} -> String.trim(release)
          {:error, _reason} -> nil
        end,
      uptime: div(uptime_ms, 1000)
    }
  end

  defp info(:system) do
    %{stats: NanoKVMGo.Metrics.current(), history: NanoKVMGo.Metrics.history()}
  catch
    :exit, _reason -> %{stats: nil, history: nil}
  end

  defp info(_page), do: %{}

  defp video do
    NanoKVMGo.Video.input()
  catch
    :exit, _reason -> nil
  end

  defp now, do: System.monotonic_time(:millisecond)
end
