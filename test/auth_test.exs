defmodule Kuroneko.AuthTest do
  use ExUnit.Case, async: false

  alias Kuroneko.Auth

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "auth.json")
    Application.put_env(:kuroneko, :auth_file, file)
    on_exit(fn -> Application.delete_env(:kuroneko, :auth_file) end)
    %{auth_file: file}
  end

  test "no password at first, then the one set", %{auth_file: file} do
    refute Auth.password_set?()
    refute Auth.verify("anything at all")
    assert Auth.set_password("short") == {:error, :too_short}

    assert :ok = Auth.set_password("long enough")
    assert Auth.password_set?()
    assert Auth.verify("long enough")
    refute Auth.verify("long enougH")
    refute File.read!(file) =~ "long enough"
    assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600
  end

  test "each password a new generation, the secret kept" do
    secret = Auth.secret()
    assert byte_size(secret) == 64
    :ok = Auth.set_password("first password")
    first = Auth.generation()
    :ok = Auth.set_password("second password")
    assert Auth.generation() == first + 1
    assert Auth.secret() == secret
  end
end
