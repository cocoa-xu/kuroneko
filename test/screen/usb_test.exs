defmodule Kuroneko.Screen.USBTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Screen.USB
  alias Kuroneko.USBSettings

  defp steps(settings, tile, n),
    do: settings |> Stream.iterate(&USB.step(&1, tile)) |> Enum.take(n + 1) |> tl()

  test "the keyboard and mice go off and on, the sound card through its modes" do
    settings = USBSettings.defaults()

    assert Enum.map(steps(settings, :input, 2), & &1["hid"]) == [false, true]
    assert Enum.map(steps(settings, :sound, 3), & &1["audio"]) == ["mic", "duplex", "off"]
  end

  test "the disk's drives go up, then the disk goes off and comes back with one" do
    drives =
      for s <- steps(USBSettings.defaults(), :drives, 7),
          do: if(s["storage"], do: s["drives"], else: :off)

    assert drives == [2, 3, 4, 8, 16, :off, 1]
    assert USB.step(%{USBSettings.defaults() | "drives" => 5}, :drives)["drives"] == 8
  end

  test "more storage devices and networks one at a time, with names of their own, none after four" do
    settings = %{USBSettings.defaults() | "storages" => [%{"name" => "disk2", "drives" => 3}]}
    [one, two, three, none] = steps(settings, :disks, 4)

    assert one["storages"] == [
             %{"name" => "disk2", "drives" => 3},
             %{"name" => "disk3", "drives" => 1}
           ]

    assert Enum.map(three["storages"], & &1["name"]) == ["disk2", "disk3", "disk4", "disk5"]
    assert length(two["storages"]) == 3
    assert none["storages"] == []

    networks = Enum.map(steps(USBSettings.defaults(), :networks, 5), & &1["networks"])
    assert hd(networks) == ["usb1"]
    assert Enum.at(networks, 3) == ["usb1", "usb2", "usb3", "usb4"]
    assert List.last(networks) == []
  end

  test "Apply sends what the page changes, and the settings take it" do
    settings = USB.step(USBSettings.defaults(), :networks)
    changes = USB.changes(settings)

    assert Map.keys(changes) |> Enum.sort() ==
             ["audio", "drives", "hid", "networks", "storage", "storages"]

    assert {:ok, %{"networks" => ["usb1"]}} =
             USBSettings.merge(USBSettings.defaults(), Map.put(changes, "hid", false))
  end
end
