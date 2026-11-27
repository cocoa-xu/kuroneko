defmodule KuronekoWeb.Format do
  @moduledoc false
  # Numbers as the pages show them: sizes, rates, durations.

  @spec bytes(number() | nil) :: String.t()
  def bytes(nil), do: "–"
  def bytes(n) when n >= 1.0e12, do: "#{decimals(n / 1.0e12, 1)} TB"
  def bytes(n) when n >= 1.0e9, do: "#{decimals(n / 1.0e9, if(n >= 1.0e11, do: 0, else: 1))} GB"
  def bytes(n) when n >= 1.0e6, do: "#{decimals(n / 1.0e6, if(n >= 1.0e8, do: 0, else: 1))} MB"
  def bytes(n) when n >= 1.0e3, do: "#{round(n / 1.0e3)} kB"
  def bytes(n), do: "#{round(n)} B"

  @spec rate(number()) :: String.t()
  def rate(n) when n >= 1.0e6, do: "#{decimals(n / 1.0e6, 1)} MB/s"
  def rate(n) when n >= 1.0e3, do: "#{round(n / 1.0e3)} kB/s"
  def rate(n), do: "#{round(n)} B/s"

  @spec duration(number() | nil) :: String.t()
  def duration(nil), do: "–"

  def duration(seconds) do
    seconds = trunc(seconds)
    {d, h, m} = {div(seconds, 86_400), rem(div(seconds, 3600), 24), rem(div(seconds, 60), 60)}

    cond do
      d > 0 -> "#{d} d #{h} h"
      h > 0 -> "#{h} h #{m} min"
      m > 0 -> "#{m} min"
      true -> "#{seconds} s"
    end
  end

  @months ~w(January February March April May June July August September October November December)

  @doc "A card's date of manufacture, `\"2023-08\"`, as `\"August 2023\"`."
  @spec month(String.t() | nil) :: String.t() | nil
  def month(nil), do: nil

  def month(date) do
    case String.split(date, "-") do
      [year, month | _] -> "#{Enum.at(@months, String.to_integer(month) - 1)} #{year}"
      _ -> date
    end
  end

  @doc "The video input, as the page says it."
  @spec input(term()) :: String.t()
  def input(%{width: w, height: h, fps: fps}), do: "#{w} × #{h} at #{fps} Hz"
  def input(:none), do: "No signal"
  def input("none"), do: "No signal"
  def input(:unsupported), do: "Unsupported signal"
  def input("unsupported"), do: "Unsupported signal"
  def input(_starting), do: "Starting"

  @usb_states %{
    "configured" => {"Connected", :ok},
    "suspended" => {"Target asleep", :warn},
    "not_attached" => {"Not connected", nil}
  }
  @usb_speeds %{
    "low_speed" => "USB 1.1 Low Speed, 1.5 Mb/s",
    "full_speed" => "USB 1.1 Full Speed, 12 Mb/s",
    "high_speed" => "USB 2.0 High Speed, 480 Mb/s",
    "super_speed" => "USB 3 SuperSpeed, 5 Gb/s",
    "super_speed_plus" => "USB 3 SuperSpeed+, 10 Gb/s"
  }

  @doc "The link to the target, `Kuroneko.Gadget.connection/1`'s, as text and a kind."
  @spec usb_state(map() | nil) :: {String.t(), :ok | :warn | :bad | nil}
  def usb_state(nil), do: {"No controller", :bad}

  def usb_state(connection),
    do: Map.get(@usb_states, to_string(connection.state), {"Connecting", nil})

  @doc "A USB link's speed."
  @spec usb_speed(atom() | nil) :: String.t()
  def usb_speed(speed), do: Map.get(@usb_speeds, to_string(speed), "Connected")

  @doc "A Wi-Fi signal's kind: `:ok`, `:warn` or `:bad`."
  @spec signal(number()) :: :ok | :warn | :bad
  def signal(dbm) when dbm >= -67, do: :ok
  def signal(dbm) when dbm >= -75, do: :warn
  def signal(_dbm), do: :bad

  @spec decimals(number(), non_neg_integer()) :: String.t()
  def decimals(x, 0), do: Integer.to_string(round(x))
  def decimals(x, n), do: :erlang.float_to_binary(x * 1.0, decimals: n)
end
