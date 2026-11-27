defmodule Kuroneko.ViewerStatsTest do
  use ExUnit.Case, async: false

  alias Kuroneko.{InputSocket, ViewerStats, VideoSocket}

  test "a page's ping comes back as a pong; its samples keep their numbers only" do
    {:ok, state} = InputSocket.init([])

    assert InputSocket.handle_in({~s({"type":"ping","t":1234.5}), opcode: :text}, state) ==
             {:push, {:text, ~s({"pong":1234.5})}, state}

    sample =
      ~s({"type":"stats","received":30,"gap_max_ms":48.2,"shown":29,"elapsed_ms":30000,"visible":0,"note":"x","decoded":"30"})

    assert InputSocket.handle_in({sample, opcode: :text}, state) == {:ok, state}

    assert %{
             received: 30,
             gap_max_ms: 48.2,
             shown: 29,
             elapsed_ms: 30000,
             visible: 0,
             viewer: viewer
           } =
             kept = ViewerStats.samples() |> List.last()

    assert viewer == state.viewer
    refute Map.has_key?(kept, :decoded)
    refute Map.has_key?(kept, :note)
  end

  test "an access unit with the time it came from the encoder, when the page asks" do
    at = System.monotonic_time(:microsecond) - 50_000

    assert {:push, {:binary, [3, <<^at::signed-64>>, "AU"]}, state} =
             VideoSocket.handle_info({NanoKVMGo.Video, {:h265, :delta, "AU", at}}, %{})

    assert {1, age, age} = state.socket_timing
    assert age >= 50_000

    assert {:push, {:text, json}, %{socket_timing: {0, 0, 0}}} =
             VideoSocket.handle_info({NanoKVMGo.Video, {:stats, %{}}}, state)

    stats = Jason.decode!(json)["stats"]
    assert stats["socket_frames"] == 1
    assert stats["socket_ms"] == age / 1000
    assert stats["socket_max_ms"] == age / 1000

    assert VideoSocket.handle_info({NanoKVMGo.Video, {:h264, :key, "AU"}}, %{}) ==
             {:push, {:binary, [2, "AU"]}, %{}}
  end

  test "the device's second of video goes to the page" do
    assert {:push, {:text, json}, %{}} =
             VideoSocket.handle_info(
               {NanoKVMGo.Video, {:stats, %{captured: 30, skipped: 0}}},
               %{}
             )

    assert %{"stats" => %{"captured" => 30, "skipped" => 0, "socket_frames" => 0}} =
             Jason.decode!(json)
  end

  test "recovery requests during the cooldown are coalesced, not lost" do
    state = %{key_request_at: System.monotonic_time(:millisecond)}
    request = {~s({"type":"keyframe"}), opcode: :text}
    assert {:ok, pending} = VideoSocket.handle_in(request, state)
    assert pending.key_pending?
    assert VideoSocket.handle_in(request, pending) == {:ok, pending}
    assert_receive :video_keyframe, 1000
    assert {:ok, next} = VideoSocket.handle_info(:video_keyframe, pending)
    refute next.key_pending?
    assert next.key_request_at >= state.key_request_at + 490
    refute_receive :video_keyframe, 20
    assert VideoSocket.handle_in({"bad json", opcode: :text}, next) == {:ok, next}
  end
end
