defmodule Kuroneko.VirtualDisk.MakerTest do
  use ExUnit.Case, async: true

  alias Kuroneko.VirtualDisk
  alias Kuroneko.VirtualDisk.Maker

  defmodule Zeros do
    @behaviour Maker

    def id, do: "zeros"
    def offers(%{kind: :image}), do: [%{mode: "zeros", label: "USB drive of zeros"}]
    def offers(_item), do: []

    def make(_item, "zeros", %{image: image, progress: progress}) do
      File.write!(image, :binary.copy(<<0>>, 4096))
      progress.(4096, 4096)
      {:ok, cdrom: false, read_only: true}
    end
  end

  defmodule Broken do
    def id, do: "broken"
    def offers(_item), do: raise("no")
    def make(_item, _mode, _context), do: {:error, :no}
  end

  defmodule Odd do
    def id, do: "odd"
    def offers(_item), do: [:not_a_map, %{mode: 1, label: "no"}, %{mode: "ok", label: "Fine"}]
    def make(_item, _mode, _context), do: {:error, :no}
  end

  test "what makers offer for an item, each with its maker's id; a failing maker offers nothing" do
    image = %{path: "/data/images/x.iso", kind: :image, format: %{disc: :dvd}}
    folder = %{path: "/data/images/x", kind: :folder, format: nil}

    assert Maker.offers([Zeros, Broken, Odd], image) == [
             %{maker: "zeros", mode: "zeros", label: "USB drive of zeros"},
             %{maker: "odd", mode: "ok", label: "Fine"}
           ]

    assert Maker.offers([Zeros], folder) == []
  end

  test "a maker is a module with the three callbacks" do
    assert Maker.maker?(Zeros)
    assert Maker.maker?(Broken)
    refute Maker.maker?(String)
    refute Maker.maker?(:nothing_by_that_name)
    refute Maker.maker?("Zeros")
  end

  test "what a maker made is remembered by its id and mode" do
    memory = VirtualDisk.memory("win.iso", "image", maker: "zeros", mode: "zeros")

    assert {:ok, %{name: "win.iso", kind: :image, opts: opts}} =
             memory |> Jason.encode!() |> Jason.decode!() |> VirtualDisk.from_memory()

    assert Enum.sort(opts) == [maker: "zeros", mode: "zeros"]
  end
end
