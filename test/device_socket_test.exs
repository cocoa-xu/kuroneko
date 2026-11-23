defmodule Kuroneko.DeviceSocketTest do
  use ExUnit.Case, async: false

  alias Kuroneko.DeviceSocket

  @moduletag :tmp_dir

  # A procfs for NanoKVMGo.Metrics, which takes samples when told.
  defp start_metrics(tmp_dir) do
    proc = Path.join(tmp_dir, "proc")
    File.mkdir_p!(Path.join(proc, "net"))
    File.write!(Path.join(proc, "stat"), "cpu  100 0 50 800 50 0 0 0 0 0\n")
    File.write!(Path.join(proc, "meminfo"), "MemTotal: 1000 kB\nMemAvailable: 600 kB\n")
    File.write!(Path.join(proc, "net/dev"), "Inter-|\n face |\n")

    start_supervised!({NanoKVMGo.Metrics, root: tmp_dir, interval: :timer.hours(1)})
  end

  defp decode({:push, {:text, json}, state}), do: {Jason.decode!(json), state}

  test "the status each second without the sampler, the samples once it comes",
       %{tmp_dir: tmp_dir} do
    {first, state} = decode(DeviceSocket.init(%{}))
    assert %{"metrics" => nil, "history" => nil, "status" => %{"beam" => _}} = first
    refute Map.has_key?(first, "storage")

    # Still no sampler: the status alone.
    assert_receive :retry, 1_500
    {message, state} = decode(DeviceSocket.handle_info(:retry, state))
    assert %{"metrics" => nil, "status" => %{"usb" => _}} = message

    # The sampler comes: subscribed at the next try.
    metrics = start_metrics(tmp_dir)
    assert_receive :retry, 1_500
    {_message, state} = decode(DeviceSocket.handle_info(:retry, state))
    assert state.metrics

    send(metrics, :sample)
    assert_receive {NanoKVMGo.Metrics, sample}
    {message, state} = decode(DeviceSocket.handle_info({NanoKVMGo.Metrics, sample}, state))
    assert %{"metrics" => %{"cpu" => %{"total" => _}}, "status" => _} = message
    refute Map.has_key?(message, "history")

    # It stops: the socket notices, and tries again.
    ref = state.metrics
    stop_supervised!(NanoKVMGo.Metrics)
    assert_receive {:DOWN, ^ref, :process, pid, reason}
    assert {:ok, state} = DeviceSocket.handle_info({:DOWN, ref, :process, pid, reason}, state)
    assert state.metrics == nil
    assert_receive :retry, 1_500
  end

  test "the storage with every 30th message" do
    {_first, state} = decode(DeviceSocket.init(%{}))

    messages =
      Enum.map_reduce(2..30, state, fn _n, state ->
        decode(DeviceSocket.handle_info(:retry, %{state | metrics: nil}))
      end)
      |> elem(0)

    assert [%{"storage" => %{"partitions" => _}}] =
             Enum.filter(messages, &Map.has_key?(&1, "storage"))

    assert Map.has_key?(List.last(messages), "storage")
  end
end
