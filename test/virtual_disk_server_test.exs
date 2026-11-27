defmodule Kuroneko.VirtualDiskServerTest do
  use ExUnit.Case, async: false

  alias Kuroneko.VirtualDisk

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "images/Windows"))
    File.write!(Path.join(tmp_dir, "images/debian.iso"), "")
    Application.put_env(:kuroneko, :virtual_disk_dir, Path.join(tmp_dir, "images"))
    Application.put_env(:kuroneko, :virtual_disk_memory, Path.join(tmp_dir, "disk.json"))

    on_exit(fn ->
      Application.delete_env(:kuroneko, :virtual_disk_dir)
      Application.delete_env(:kuroneko, :virtual_disk_memory)
    end)

    start_supervised!(VirtualDisk)
    :ok
  end

  test "the drives as the state says them, without the library" do
    state = VirtualDisk.state()
    assert Enum.map(state.items, & &1.name) == ["Windows", "debian.iso"]
    assert VirtualDisk.drives() == Map.take(state, [:drives, :busy])
  end
end
