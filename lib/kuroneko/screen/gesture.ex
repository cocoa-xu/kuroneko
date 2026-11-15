defmodule Kuroneko.Screen.Gesture do
  @moduledoc """
  What a touch on the LCD did, from where it went down to where it came up:
  a tap if it stayed put, a swipe if it went far enough one way.

      iex> Kuroneko.Screen.Gesture.classify({100, 100}, {104, 97})
      {:tap, {100, 100}}
      iex> Kuroneko.Screen.Gesture.classify({180, 120}, {60, 130})
      {:swipe, :left}
  """

  @tap_radius 14
  @swipe_distance 30

  @type point() :: {integer(), integer()}
  @type t() :: {:tap, point()} | {:swipe, :left | :right | :up | :down} | :none

  @doc "The gesture of a touch that went down at one point and up at another."
  @spec classify(point(), point()) :: t()
  def classify({x0, y0} = from, {x1, y1}) do
    {dx, dy} = {x1 - x0, y1 - y0}

    cond do
      abs(dx) < @tap_radius and abs(dy) < @tap_radius ->
        {:tap, from}

      abs(dx) >= abs(dy) and abs(dx) >= @swipe_distance ->
        {:swipe, if(dx < 0, do: :left, else: :right)}

      abs(dy) > abs(dx) and abs(dy) >= @swipe_distance ->
        {:swipe, if(dy < 0, do: :up, else: :down)}

      true ->
        :none
    end
  end
end
