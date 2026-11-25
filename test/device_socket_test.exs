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

  test "the status each second without the sampler" do
    {first, state} = decode(DeviceSocket.init(%{}))
    assert %{"metrics" => nil, "history" => nil, "status" => %{"beam" => _}} = first
    refute Map.has_key?(first, "storage")

    assert_receive :status, 2_000
    {message, _state} = decode(DeviceSocket.handle_info(:status, state))
    assert %{"metrics" => nil, "status" => %{"usb" => _}} = message
  end

  test "the samples with the status, until the sampler stops", %{tmp_dir: tmp_dir} do
    metrics = start_metrics(tmp_dir)
    {first, state} = decode(DeviceSocket.init(%{}))
    assert %{"metrics" => nil, "history" => %{}, "status" => _} = first

    send(metrics, :sample)
    assert_receive {NanoKVMGo.Metrics, sample}
    {message, state} = decode(DeviceSocket.handle_info({NanoKVMGo.Metrics, sample}, state))
    assert %{"metrics" => %{"cpu" => %{"total" => _}}, "status" => _} = message
    refute Map.has_key?(message, "history")

    stop_supervised!(NanoKVMGo.Metrics)
    assert_receive {:DOWN, _monitor, :process, _pid, _reason} = down
    assert {:stop, :normal, {1011, _reason}, _state} = DeviceSocket.handle_info(down, state)
  end

  test "the storage with every 30th message" do
    {_first, state} = decode(DeviceSocket.init(%{}))

    messages =
      Enum.map_reduce(2..30, state, fn _n, state ->
        decode(DeviceSocket.handle_info(:status, state))
      end)
      |> elem(0)

    assert [%{"storage" => %{"partitions" => _}}] =
             Enum.filter(messages, &Map.has_key?(&1, "storage"))

    assert Map.has_key?(List.last(messages), "storage")
  end
end
