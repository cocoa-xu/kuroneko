defmodule Kuroneko.BrowserInputTest do
  use ExUnit.Case, async: true

  alias Kuroneko.BrowserInput

  test "keys" do
    assert BrowserInput.parse(%{"type" => "key", "code" => "KeyA", "down" => true}) ==
             {:key, "KeyA", :down}

    assert BrowserInput.parse(%{"type" => "key", "code" => "KeyA", "down" => false}) ==
             {:key, "KeyA", :up}

    assert BrowserInput.parse(%{"type" => "key", "code" => 4, "down" => true}) == :ignore
  end

  test "pointer: buttons as names, the wheel turned upside down" do
    assert BrowserInput.parse(%{"type" => "mouse", "x" => 0.25, "y" => 1, "buttons" => 5}) ==
             {:pointer, [x: 0.25, y: 1, buttons: [:left, :middle], wheel: 0, pan: 0]}

    assert {:pointer, changes} =
             BrowserInput.parse(%{"type" => "mouse", "x" => 0, "y" => 0, "wheel" => 1})

    assert changes[:wheel] == -1
    assert changes[:buttons] == []
    assert BrowserInput.parse(%{"type" => "mouse", "x" => "0", "y" => 0}) == :ignore
  end

  test "relative movement, with the back and forward buttons and both wheels" do
    event = %{"type" => "relative", "dx" => -3, "dy" => 200, "buttons" => 24, "pan" => 2.5}

    assert BrowserInput.parse(event) ==
             {:relative, [dx: -3, dy: 200, buttons: [:back, :forward], wheel: 0, pan: 3]}

    assert BrowserInput.parse(%{"type" => "relative", "dx" => 0.5, "dy" => 0}) == :ignore
  end

  test "touches, the bad ones left out" do
    touches = [[0, 0.1, 0.2], [12, 0.5, 0.5], [1, "x", 0], [2, 0.9, 1]]

    assert BrowserInput.parse(%{"type" => "touch", "touches" => touches}) ==
             {:touch, [{0, 0.1, 0.2}, {2, 0.9, 1}]}

    assert BrowserInput.parse(%{"type" => "touch", "touches" => []}) == {:touch, []}
  end

  test "text to type, up to a length" do
    assert BrowserInput.parse(%{"type" => "text", "text" => "hi\n"}) == {:text, "hi\n"}

    assert BrowserInput.parse(%{"type" => "text", "text" => String.duplicate("a", 10_001)}) ==
             :ignore
  end

  test "release and anything else" do
    assert BrowserInput.parse(%{"type" => "release"}) == :release
    assert BrowserInput.parse(%{"type" => "paste", "text" => "hi"}) == :ignore
  end

  test "events reach Kuroneko.Gadget.Input" do
    dir = Path.join(System.tmp_dir!(), "browser_input_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    keyboard = Path.join(dir, "keyboard")
    File.write!(keyboard, "")

    hid =
      start_supervised!({Kuroneko.Gadget.Input, keyboard: keyboard, mouse: keyboard, name: nil})

    BrowserInput.handle(%{"type" => "key", "code" => "KeyB", "down" => true}, hid)
    assert %{keyboard: %{sent: 1}} = Kuroneko.Gadget.Input.stats(hid)
  end
end
