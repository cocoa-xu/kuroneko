defmodule Kuroneko.ViewerStatsTest do
  use ExUnit.Case, async: false

  alias Kuroneko.{InputSocket, ViewerStats, VideoSocket}

  test "a page's ping comes back as a pong; its samples keep their numbers only" do
    {:ok, state} = InputSocket.init([])

    assert InputSocket.handle_in({~s({"type":"ping","t":1234.5}), opcode: :text}, state) ==
             {:push, {:text, ~s({"pong":1234.5})}, state}

    sample =
      ~s({"type":"stats","received":30,"gap_max_ms":48.2,"shown":29,"note":"x","decoded":"30"})

    assert InputSocket.handle_in({sample, opcode: :text}, state) == {:ok, state}

    assert %{received: 30, gap_max_ms: 48.2, shown: 29, viewer: viewer} =
             kept = ViewerStats.samples() |> List.last()

    assert viewer == state.viewer
    refute Map.has_key?(kept, :decoded)
    refute Map.has_key?(kept, :note)
  end

  test "the device's second of video goes to the page" do
    assert VideoSocket.handle_info({NanoKVMGo.Video, {:stats, %{captured: 30, skipped: 0}}}, %{}) ==
             {:push, {:text, ~s({"captured":30,"skipped":0}) |> then(&~s({"stats":#{&1}}))}, %{}}
  end
end
