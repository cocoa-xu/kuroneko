defmodule Kuroneko.MigrationTest do
  use ExUnit.Case, async: true

  alias Kuroneko.Migration

  @moduletag :tmp_dir

  test "moves the old state and leaves a link to it", %{tmp_dir: data} do
    old = Path.join(data, "nanokvm_hello")
    File.mkdir_p!(Path.join(old, "tls"))
    File.write!(Path.join(old, "auth.json"), "{}")

    assert :ok = Migration.run(data)
    assert File.read!(Path.join(data, "kuroneko/auth.json")) == "{}"
    assert File.dir?(Path.join(data, "kuroneko/tls"))
    assert File.read_link!(old) == "kuroneko"
    assert File.read!(Path.join(old, "auth.json")) == "{}"

    # Once moved, nothing more to do.
    assert :ok = Migration.run(data)
    assert File.read_link!(old) == "kuroneko"
  end

  test "leaves things alone without old state or with new state", %{tmp_dir: data} do
    assert :ok = Migration.run(data)
    refute File.exists?(Path.join(data, "kuroneko"))

    File.mkdir_p!(Path.join(data, "nanokvm_hello"))
    File.mkdir_p!(Path.join(data, "kuroneko"))
    assert :ok = Migration.run(data)
    assert File.dir?(Path.join(data, "nanokvm_hello"))
    assert {:error, :einval} = File.read_link(Path.join(data, "nanokvm_hello"))
  end
end
