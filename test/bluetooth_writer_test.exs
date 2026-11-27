defmodule Kuroneko.Bluetooth.WriterTest do
  use ExUnit.Case, async: false

  alias Kuroneko.Bluetooth.Writer

  # Stands in for NanoKVMGo.Bluetooth.HID: its reports arrive as casts.
  setup do
    Process.register(self(), NanoKVMGo.Bluetooth.HID)
    :ok
  end

  defp next_report do
    receive do
      {:"$gen_cast", {:report, name, report}} -> {name, report}
    after
      1_000 -> :none
    end
  end

  test "the absolute mouse moves the pointer; its buttons and wheels go through the relative one" do
    {:ok, writer} = Writer.start_link(:mouse)

    send(writer, {:report, <<0, 100::little-16, 200::little-16, 0, 0>>})
    assert next_report() == {:mouse, <<0, 100::little-16, 200::little-16, 0, 0>>}

    # A press where the pointer goes: the move first, then the button
    send(writer, {:report, <<1, 300::little-16, 400::little-16, 0, 0>>})
    assert next_report() == {:mouse, <<0, 300::little-16, 400::little-16, 0, 0>>}
    assert next_report() == {:relative_mouse, <<1, 0, 0, 0, 0>>}

    # Dragging holds the button; the release goes alone
    send(writer, {:report, <<1, 310::little-16, 400::little-16, 0, 0>>})
    assert next_report() == {:mouse, <<0, 310::little-16, 400::little-16, 0, 0>>}
    send(writer, {:report, <<0, 310::little-16, 400::little-16, 0, 0>>})
    assert next_report() == {:relative_mouse, <<0, 0, 0, 0, 0>>}

    # Scrolling: the wheel's steps, each report
    send(writer, {:report, <<0, 310::little-16, 400::little-16, 0xFF, 0>>})
    assert next_report() == {:relative_mouse, <<0, 0, 0, 0xFF, 0>>}
    assert next_report() == :none
  end

  test "positions faster than a connection interval: the newest goes once the interval is over" do
    {:ok, writer} = Writer.start_link(:mouse)

    for x <- [100, 110, 120, 130],
        do: send(writer, {:report, <<0, x::little-16, 200::little-16, 0, 0>>})

    assert next_report() == {:mouse, <<0, 100::little-16, 200::little-16, 0, 0>>}
    assert next_report() == {:mouse, <<0, 130::little-16, 200::little-16, 0, 0>>}
    assert next_report() == :none
  end

  test "relative steps add up meanwhile, in steps of 127 at most; a press after the movement" do
    {:ok, writer} = Writer.start_link(:relative_mouse)

    for _ <- 1..4, do: send(writer, {:report, <<0, 100, 0, 0, 0>>})
    assert next_report() == {:relative_mouse, <<0, 100, 0, 0, 0>>}
    assert next_report() == {:relative_mouse, <<0, 127, 0, 0, 0>>}
    assert next_report() == {:relative_mouse, <<0, 127, 0, 0, 0>>}
    assert next_report() == {:relative_mouse, <<0, 46, 0, 0, 0>>}

    send(writer, {:report, <<0, 5, -3::signed, 0, 0>>})
    send(writer, {:report, <<1, 0, 0, 0, 0>>})
    assert next_report() == {:relative_mouse, <<0, 5, -3::signed, 0, 0>>}
    assert next_report() == {:relative_mouse, <<1, 0, 0, 0, 0>>}
    assert next_report() == :none
  end

  test "other devices' reports go as they are" do
    {:ok, writer} = Writer.start_link(:keyboard)
    send(writer, {:report, <<0, 0, 4, 0, 0, 0, 0, 0>>})
    assert next_report() == {:keyboard, <<0, 0, 4, 0, 0, 0, 0, 0>>}
  end
end
