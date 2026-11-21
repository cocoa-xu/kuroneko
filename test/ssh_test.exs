defmodule Kuroneko.SSHTest do
  use ExUnit.Case, async: false

  alias Kuroneko.{Auth, LoginLimit, SSH}

  @moduletag :tmp_dir
  @ed25519 "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICfSM6txorN3hZNHrTo+2d55zGcF5N+xgdsl2aDIbbcT test@example.com"
  @ecdsa "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBDK4gMQkua8q0bD/4TpPeQvCzW/G5LdOVW6aox8wKci4xFGDSdUO0XeyfccpPgSubmXqwgoURq+yxfPakOa6L/8= other@example.com"

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:kuroneko, :auth_file, Path.join(tmp_dir, "auth.json"))
    LoginLimit.reset()
    on_exit(fn -> Application.delete_env(:kuroneko, :auth_file) end)
  end

  test "the page's password logs in over SSH, whatever the user name" do
    refute SSH.check_password(~c"anyone", ~c"long enough", :peer, :undefined)

    :ok = Auth.set_password("long enough")
    assert SSH.check_password(~c"root", ~c"long enough", :peer, :undefined)
    assert SSH.check_password(~c"me", ~c"long enough", :peer, :undefined)
    refute SSH.check_password(~c"me", ~c"wrong", :peer, :undefined)
  end

  test "five wrong passwords, from SSH or the page, close SSH for a minute" do
    :ok = Auth.set_password("long enough")
    for _ <- 1..5, do: refute(SSH.check_password(~c"me", ~c"wrong", :peer, :undefined))
    assert SSH.check_password(~c"me", ~c"long enough", :peer, :undefined) == :disconnect
  end

  test "a key's type, fingerprint and comment" do
    assert {:ok, key} = SSH.describe(@ed25519)
    assert key.type == "ssh-ed25519"
    assert key.fingerprint == "SHA256:prP84fytM7VWEa/GDXRUSuzgcqaKqZmc6XWe7cHuKLM"
    assert key.comment == "test@example.com"
    assert {:ok, %{type: "ecdsa-sha2-nistp256"}} = SSH.describe(@ecdsa)
    assert SSH.describe("ssh-ed25519 not-base64") == {:error, :invalid_key}
  end

  test "keys one per line; one that is not a key fails them all" do
    assert SSH.parse("#{@ed25519}\r\n\n# mine\n  #{@ecdsa}  \n") == {:ok, [@ed25519, @ecdsa]}
    assert SSH.parse("#{@ed25519}\nnot a key") == {:error, :invalid_key}
    assert SSH.parse("  \n# only a comment\n") == {:error, :invalid_key}
    assert SSH.parse("-----BEGIN OPENSSH PRIVATE KEY-----") == {:error, :invalid_key}
  end

  test "keys built into the firmware stay" do
    Application.put_env(:nerves_ssh, :authorized_keys, [@ed25519])
    on_exit(fn -> Application.delete_env(:nerves_ssh, :authorized_keys) end)

    assert SSH.remove_key(@ed25519) == {:error, :built_in}
    # The host has no SSH daemon.
    assert SSH.remove_key(@ecdsa) == {:error, :no_ssh}
    assert SSH.add_keys(@ecdsa) == {:error, :no_ssh}
    assert SSH.keys() == []
  end
end
