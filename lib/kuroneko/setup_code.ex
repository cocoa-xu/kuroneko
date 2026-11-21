defmodule Kuroneko.SetupCode do
  @moduledoc """
  The code the LCD shows while the page has no password. Setting the first
  password takes it, so that someone at the device sets it, not whoever
  opens the page first. A wrong code brings a new one, and failures count
  with the logins' (`Kuroneko.LoginLimit`).
  """
  use Agent

  @spec start_link(term()) :: Agent.on_start()
  def start_link(_arg), do: Agent.start_link(&generate/0, name: __MODULE__)

  @doc "The code to show, `nil` once a password is set."
  @spec current() :: String.t() | nil
  def current do
    if Kuroneko.Auth.password_set?(), do: nil, else: Agent.get(__MODULE__, & &1)
  end

  @doc "Whether `code` is the one shown, spaces aside; a wrong one is replaced."
  @spec check(term()) :: boolean()
  def check(code) do
    Agent.get_and_update(__MODULE__, fn current ->
      if is_binary(code) and Plug.Crypto.secure_compare(String.replace(code, " ", ""), current),
        do: {true, current},
        else: {false, generate()}
    end)
  end

  @doc "Six random digits."
  @spec generate() :: String.t()
  def generate do
    <<n::32>> = :crypto.strong_rand_bytes(4)
    n |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end
end
