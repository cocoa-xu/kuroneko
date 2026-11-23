defmodule Kuroneko.Screen.Calibration do
  @moduledoc """
  From the touch panel's points to the display's:

      x' = a * x + b * y + c
      y' = d * x + e * y + f

  fitted by least squares to touches on targets at known places, as tslib
  does. Without a calibration the panel's 296 rows are spread over the
  display's 284.
  """

  @type t() :: {float(), float(), float(), float(), float(), float()}
  @type point() :: {number(), number()}

  # A touch farther than this from its target after the fit missed it. A
  # corner's own touch pulls the fit towards it: a miss shows as about a
  # third of its distance.
  @max_error 10

  @doc "The mapping without a calibration."
  @spec default() :: t()
  def default, do: {1.0, 0.0, 0.0, 0.0, 284 / 296, 0.0}

  @doc """
  Where on the display a point of the touch panel is.

      iex> Kuroneko.Screen.Calibration.to_display({1.0, 0.0, 2.0, 0.0, 0.5, 0.0}, {10, 40})
      {12, 20}
  """
  @spec to_display(t(), point()) :: {integer(), integer()}
  def to_display({a, b, c, d, e, f}, {x, y}),
    do: {round(a * x + b * y + c), round(d * x + e * y + f)}

  @doc """
  The calibration from touches, each the panel's point and the display's
  target it was on: at least three, not in a line. It fails when a touch
  missed its target or the result is not a panel over a display.
  """
  @spec fit([{point(), point()}]) :: {:ok, t()} | {:error, :singular | :missed | :implausible}
  def fit(pairs) when length(pairs) >= 3 do
    rows = for {{x, y}, _target} <- pairs, do: [x / 1, y / 1, 1.0]

    with {:ok, [a, b, c]} <- least_squares(rows, for({_point, {x, _y}} <- pairs, do: x / 1)),
         {:ok, [d, e, f]} <- least_squares(rows, for({_point, {_x, y}} <- pairs, do: y / 1)) do
      check({a, b, c, d, e, f}, pairs)
    end
  end

  @doc """
  Whether coefficients could be a calibration of this panel: little
  rotation and shear, a scale near one, an offset within the display.
  """
  @spec plausible?(t()) :: boolean()
  def plausible?({a, b, c, d, e, f}) do
    a > 0.5 and a < 2 and e > 0.5 and e < 2 and abs(b) < 0.3 and abs(d) < 0.3 and abs(c) < 120 and
      abs(f) < 120
  end

  defp check(coefficients, pairs) do
    worst =
      pairs
      |> Enum.map(fn {point, {tx, ty}} ->
        {x, y} = exact(coefficients, point)
        :math.sqrt((x - tx) ** 2 + (y - ty) ** 2)
      end)
      |> Enum.max()

    cond do
      not plausible?(coefficients) -> {:error, :implausible}
      worst > @max_error -> {:error, :missed}
      true -> {:ok, coefficients}
    end
  end

  defp exact({a, b, c, d, e, f}, {x, y}), do: {a * x + b * y + c, d * x + e * y + f}

  # The normal equations (AᵀA)p = Aᵀt, solved by Cramer's rule.
  defp least_squares(rows, targets) do
    columns = Enum.zip_with(rows, & &1)
    matrix = for i <- columns, do: for(j <- columns, do: dot(i, j))
    solve(matrix, for(column <- columns, do: dot(column, targets)))
  end

  defp dot(u, v), do: u |> Enum.zip_with(v, &(&1 * &2)) |> Enum.sum()

  defp solve([[m11, _, _], [_, m22, _], [_, _, m33]] = matrix, vector) do
    det = det3(matrix)

    if abs(det) <= 1.0e-9 * abs(m11 * m22 * m33) do
      {:error, :singular}
    else
      {:ok, for(column <- 0..2, do: det3(replace_column(matrix, column, vector)) / det)}
    end
  end

  defp det3([[a, b, c], [d, e, f], [g, h, i]]),
    do: a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)

  defp replace_column(matrix, column, vector),
    do: Enum.zip_with(matrix, vector, &List.replace_at(&1, column, &2))
end
