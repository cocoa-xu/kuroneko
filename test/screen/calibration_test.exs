defmodule Kuroneko.Screen.CalibrationTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Screen.Calibration

  doctest Calibration

  @targets [{40, 60}, {200, 60}, {200, 220}, {40, 220}, {120, 140}]

  # Where a panel that maps x' = 1.05x - 8, y' = 0.9y + 12 reports each target.
  defp touches(targets) do
    for {x, y} <- targets, do: {{(x + 8) / 1.05, (y - 12) / 0.9}, {x, y}}
  end

  test "finds the panel's mapping from touches on targets" do
    assert {:ok, {a, b, c, d, e, f}} = Calibration.fit(touches(@targets))

    for {expected, value} <- [{1.05, a}, {0.0, b}, {-8.0, c}, {0.0, d}, {0.9, e}, {12.0, f}],
        do: assert_in_delta(value, expected, 1.0e-6)

    assert Calibration.to_display({a, b, c, d, e, f}, {100, 100}) == {97, 102}
  end

  test "a touch far from its target fails" do
    [{{x, y}, target} | rest] = touches(@targets)
    assert Calibration.fit([{{x + 60, y}, target} | rest]) == {:error, :missed}
  end

  test "touches in a line give no calibration" do
    line = for x <- [20, 60, 100], do: {{x, x}, {x, x}}
    assert Calibration.fit(line) == {:error, :singular}
  end

  test "a mirrored panel is not one" do
    mirrored = for {{x, y}, {tx, ty}} <- touches(@targets), do: {{240 - x, y}, {tx, ty}}
    assert Calibration.fit(mirrored) == {:error, :implausible}
  end

  test "without a calibration the panel's rows spread over the display's" do
    assert Calibration.to_display(Calibration.default(), {120, 296}) == {120, 284}
  end
end
