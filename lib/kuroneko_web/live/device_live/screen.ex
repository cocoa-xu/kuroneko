defmodule KuronekoWeb.DeviceLive.Screen do
  @moduledoc false
  # The LCD: brightness, the backlight's PWM, rotation, sleep and the touch
  # panel's calibration. Each change applies at once.

  use KuronekoWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kuroneko.DeviceInfo

  @pwm [200, 500, 1000, 2160, 5000, 10_000, 25_000, 50_000, 100_000, 300_000]
  @sleep [
    {0, "Never"},
    {1, "After a minute"},
    {5, "After 5 minutes"},
    {15, "After 15 minutes"},
    {60, "After an hour"}
  ]

  attr :screen, :map, default: nil
  attr :custom, :boolean, default: false, doc: "the custom PWM frequency's field shown"

  def screen_card(assigns) do
    screen = assigns.screen

    assigns =
      assign(assigns,
        pwm_options: screen && pwm_options(screen),
        sleep_options: screen && options_with(@sleep, screen.sleep, &"After #{&1} minutes")
      )

    ~H"""
    <.card id="screen" title="Screen" icon="hero-device-phone-mobile">
      <:actions>
        <.badge kind={backlight_kind(@screen)}>{backlight_text(@screen)}</.badge>
      </:actions>

      <%= if @screen do %>
        <.group>
          <.row label="Brightness">
            <form
              id="screen-brightness"
              phx-change="screen:brightness"
              phx-auto-recover="ignore"
              class="flex w-48 items-center gap-3"
            >
              <input
                type="range"
                name="brightness"
                min="5"
                max="100"
                value={@screen.brightness}
                phx-debounce="120"
                class="range range-primary range-xs flex-1"
                oninput="this.nextElementSibling.textContent = this.value + '%'"
              />
              <output class="w-10 text-right text-sm tabular-nums">{@screen.brightness}%</output>
            </form>
          </.row>

          <.row label="Backlight PWM">
            <div class="flex items-center gap-2">
              <form id="screen-pwm" phx-change="screen:pwm" phx-auto-recover="ignore">
                <select name="pwm" class="select select-sm w-44">
                  <option
                    :for={{value, label} <- @pwm_options}
                    value={value}
                    selected={selected?(@screen, value, @custom)}
                  >
                    {label}
                  </option>
                </select>
              </form>
              <form
                :if={@custom}
                id="screen-pwm-hz"
                phx-submit="screen:pwm_hz"
                class="flex items-center gap-1.5"
              >
                <input
                  type="number"
                  name="hz"
                  min="1"
                  max="1000000"
                  step="1"
                  placeholder="Hz"
                  class="input input-sm w-24"
                  aria-label="Frequency in Hz"
                />
                <.button size={:sm} type="submit">Set</.button>
              </form>
            </div>
          </.row>

          <.row label="Rotation">
            <.segmented
              label="Rotation"
              event="screen:rotate"
              value={@screen.rotate}
              options={[{0, "Upright"}, {180, "Upside down"}]}
            />
          </.row>

          <.row label="Screen off">
            <form id="screen-sleep" phx-change="screen:sleep" phx-auto-recover="ignore">
              <select name="sleep" class="select select-sm w-44">
                <option
                  :for={{value, label} <- @sleep_options}
                  value={value}
                  selected={value == @screen.sleep}
                >
                  {label}
                </option>
              </select>
            </form>
          </.row>

          <.row
            label="Touch panel"
            detail={if @screen.calibration, do: "Calibrated", else: "Not calibrated"}
          >
            <.button size={:sm} phx-click="screen:reset_calibration" disabled={!@screen.calibration}>
              Reset calibration
            </.button>
          </.row>
        </.group>

        <p class="mt-4 text-xs text-base-content/55">
          Brightness follows the same curve at any PWM frequency. Below about 100 Hz the light flickers; from
          about 100 kHz low brightness may come out brighter. Calibrate the touch panel on the screen itself:
          Settings, Touch panel, Calibrate.
        </p>
      <% else %>
        <p class="text-sm text-base-content/60">The screen is not running.</p>
      <% end %>
    </.card>
    """
  end

  defp backlight_kind(%{backlight: %{on: true}}), do: :ok
  defp backlight_kind(nil), do: :bad
  defp backlight_kind(_screen), do: nil

  defp backlight_text(nil), do: "Not running"
  defp backlight_text(%{backlight: nil}), do: "Backlight unknown"

  defp backlight_text(%{backlight: %{on: true, frequency: f}}) when is_number(f),
    do: "On at #{hertz(f)}"

  defp backlight_text(%{backlight: %{on: true}}), do: "On"
  defp backlight_text(_screen), do: "Off, asleep"

  defp pwm_options(screen) do
    default =
      if screen[:pwm_default], do: "Default, #{hertz(screen.pwm_default)}", else: "Default"

    listed = options_with(Enum.map(@pwm, &{&1, pwm_label(&1)}), screen.pwm_frequency, &hertz/1)
    [{"", default} | listed] ++ [{"custom", "Custom…"}]
  end

  defp pwm_label(2160), do: "2.16 kHz, as stock"
  defp pwm_label(hz), do: hertz(hz)

  defp selected?(_screen, "custom", custom), do: custom
  defp selected?(_screen, _value, true), do: false
  defp selected?(%{pwm_frequency: nil}, "", _custom), do: true
  defp selected?(screen, value, _custom), do: value == screen.pwm_frequency

  # The options, and the current value among them when the list lacks it.
  defp options_with(options, nil, _label), do: options

  defp options_with(options, value, label) do
    if List.keymember?(options, value, 0),
      do: options,
      else: Enum.sort_by([{value, label.(value)} | options], &elem(&1, 0))
  end

  @doc false
  def hertz(hz) when hz >= 1000, do: "#{trim(Float.round(hz / 1000, 2))} kHz"
  def hertz(hz), do: "#{round(hz)} Hz"

  defp trim(f), do: if(f == trunc(f), do: trunc(f), else: f)

  def event("brightness", %{"brightness" => b}, socket),
    do: change(socket, %{"brightness" => String.to_integer(b)})

  def event("pwm", %{"pwm" => "custom"}, socket),
    do: {:noreply, assign(socket, screen_custom: true)}

  def event("pwm", %{"pwm" => ""}, socket),
    do: change(socket, %{"pwm_frequency" => nil}, "Backlight PWM at the default")

  def event("pwm", %{"pwm" => hz}, socket) do
    hz = String.to_integer(hz)
    change(socket, %{"pwm_frequency" => hz}, "Backlight PWM at #{hertz(hz)}")
  end

  def event("pwm_hz", %{"hz" => text}, socket) do
    case Integer.parse(text) do
      {hz, ""} when hz in 1..1_000_000 ->
        change(
          assign(socket, screen_custom: false),
          %{"pwm_frequency" => hz},
          "Backlight PWM at #{hertz(hz)}"
        )

      _ ->
        {:noreply, put_flash(socket, :error, "A frequency from 1 Hz to 1 MHz")}
    end
  end

  def event("rotate", %{"value" => value}, socket) do
    rotate = String.to_integer(value)

    change(
      socket,
      %{"rotate" => rotate},
      if(rotate == 0, do: "Screen upright", else: "Screen upside down")
    )
  end

  def event("sleep", %{"sleep" => minutes}, socket),
    do: change(socket, %{"sleep" => String.to_integer(minutes)})

  def event("reset_calibration", _params, socket),
    do: change(socket, %{"calibration" => nil}, "Calibration reset")

  defp change(socket, changes, done \\ nil) do
    case Kuroneko.Screen.update(changes) do
      {:ok, _settings} ->
        socket = assign(socket, status: DeviceInfo.status())
        {:noreply, if(done, do: put_flash(socket, :info, done), else: socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Screen: #{inspect(reason)}")}
    end
  end
end
