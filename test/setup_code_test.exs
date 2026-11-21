defmodule Kuroneko.SetupCodeTest do
  use ExUnit.Case, async: false

  alias Kuroneko.{Auth, SetupCode}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:kuroneko, :auth_file, Path.join(tmp_dir, "auth.json"))
    on_exit(fn -> Application.delete_env(:kuroneko, :auth_file) end)
  end

  test "six digits, shown until a password is set" do
    code = SetupCode.current()
    assert code =~ ~r/^\d{6}$/
    assert SetupCode.current() == code

    :ok = Auth.set_password("long enough")
    assert SetupCode.current() == nil
  end

  test "the code shown passes, with or without spaces; a wrong one brings a new code" do
    code = SetupCode.current()
    spaced = String.slice(code, 0, 3) <> " " <> String.slice(code, 3, 3)

    assert SetupCode.check(spaced)
    assert SetupCode.check(code)
    assert SetupCode.current() == code

    wrong = code |> String.to_integer() |> Kernel.+(1) |> rem(1_000_000) |> Integer.to_string()
    refute SetupCode.check(String.pad_leading(wrong, 6, "0"))
    # A new code: the old one is wrong now, unless the dice gave it again.
    assert SetupCode.current() != code
    refute SetupCode.check(nil)
  end

  test "codes are spread over all six digits" do
    codes = for _ <- 1..200, do: SetupCode.generate()
    assert Enum.all?(codes, &(&1 =~ ~r/^\d{6}$/))
    assert length(Enum.uniq(codes)) > 190
  end
end
