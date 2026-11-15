defmodule Kuroneko.Screen.Settings do
  @moduledoc """
  What the LCD keeps across restarts, in a JSON file: the rotation (0 or
  180 degrees), the brightness (5 to 100 percent), the minutes without a
  touch before the backlight goes off (0 for never), the touch panel's
  calibration (`nil` for none), and the backlight's PWM frequency in Hz
  (`nil` for the device tree's, 1 to 1 000 000 for your own).
  """

  alias Kuroneko.Screen.Calibration

  defstruct rotate: 0, brightness: 100, sleep: 0, calibration: nil, pwm_frequency: nil

  @type t() :: %__MODULE__{
          rotate: 0 | 180,
          brightness: 5..100,
          sleep: 0..1440,
          calibration: Calibration.t() | nil,
          pwm_frequency: pos_integer() | nil
        }

  @doc "The settings in a file, or the defaults; values that do not fit are left out."
  @spec load(Path.t()) :: t()
  def load(path) do
    with {:ok, json} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      Enum.reduce(map, %__MODULE__{}, fn {key, value}, settings ->
        case put(settings, key, value) do
          {:ok, settings} -> settings
          :error -> settings
        end
      end)
    else
      _ -> %__MODULE__{}
    end
  end

  @doc """
  Writes the settings, the whole file or nothing.
  """
  @spec save(t(), Path.t()) :: :ok | {:error, term()}
  def save(settings, path) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Jason.encode!(to_map(settings))) do
      File.rename(tmp, path)
    end
  end

  @doc """
  Settings with changes, string or atom keys, all checked before any is
  taken.

      iex> {:ok, settings} = Kuroneko.Screen.Settings.merge(%Kuroneko.Screen.Settings{}, %{"rotate" => 180})
      iex> settings.rotate
      180
      iex> Kuroneko.Screen.Settings.merge(%Kuroneko.Screen.Settings{}, %{brightness: 0})
      {:error, {:invalid, "brightness"}}
  """
  @spec merge(t(), map()) :: {:ok, t()} | {:error, {:invalid, String.t()} | :not_an_object}
  def merge(settings, changes) when is_map(changes) do
    Enum.reduce_while(changes, {:ok, settings}, fn {key, value}, {:ok, settings} ->
      case put(settings, to_string(key), value) do
        {:ok, settings} -> {:cont, {:ok, settings}}
        :error -> {:halt, {:error, {:invalid, to_string(key)}}}
      end
    end)
  end

  def merge(_settings, _changes), do: {:error, :not_an_object}

  @doc "The settings as JSON takes them."
  @spec to_map(t()) :: map()
  def to_map(settings) do
    %{
      rotate: settings.rotate,
      brightness: settings.brightness,
      sleep: settings.sleep,
      calibration: settings.calibration && Tuple.to_list(settings.calibration),
      pwm_frequency: settings.pwm_frequency
    }
  end

  defp put(settings, "rotate", rotate) when rotate in [0, 180],
    do: {:ok, %{settings | rotate: rotate}}

  defp put(settings, "brightness", percent) when is_integer(percent) and percent in 5..100,
    do: {:ok, %{settings | brightness: percent}}

  defp put(settings, "sleep", minutes) when is_integer(minutes) and minutes in 0..1440,
    do: {:ok, %{settings | sleep: minutes}}

  defp put(settings, "pwm_frequency", nil), do: {:ok, %{settings | pwm_frequency: nil}}

  defp put(settings, "pwm_frequency", hz) when is_integer(hz) and hz in 1..1_000_000,
    do: {:ok, %{settings | pwm_frequency: hz}}

  defp put(settings, "calibration", nil), do: {:ok, %{settings | calibration: nil}}

  defp put(settings, "calibration", [_, _, _, _, _, _] = values) do
    with true <- Enum.all?(values, &is_number/1),
         calibration = values |> Enum.map(&(&1 / 1)) |> List.to_tuple(),
         true <- Calibration.plausible?(calibration) do
      {:ok, %{settings | calibration: calibration}}
    else
      false -> :error
    end
  end

  defp put(_settings, _key, _value), do: :error
end
