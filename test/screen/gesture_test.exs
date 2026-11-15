defmodule Kuroneko.Screen.GestureTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Screen.Gesture

  doctest Gesture

  test "a touch that stays put is a tap where it went down" do
    assert Gesture.classify({50, 60}, {50, 60}) == {:tap, {50, 60}}
    assert Gesture.classify({50, 60}, {63, 47}) == {:tap, {50, 60}}
  end

  test "a touch that goes far one way is a swipe that way" do
    assert Gesture.classify({50, 100}, {150, 110}) == {:swipe, :right}
    assert Gesture.classify({100, 200}, {110, 120}) == {:swipe, :up}
    assert Gesture.classify({100, 100}, {90, 160}) == {:swipe, :down}
  end

  test "a short slide is neither" do
    assert Gesture.classify({100, 100}, {120, 110}) == :none
  end
end
