defmodule Kuroneko.SSH do
  @moduledoc """
  Who may log in over SSH: any user name with the page's password
  (`Kuroneko.Auth`), its failures counted with the page's
  (`Kuroneko.LoginLimit`), or one of the keys `keys/0` lists.

  Keys come built into the firmware (`config/authorized_keys`), from the
  card (`Kuroneko.Provisioning`) or from the settings page. NervesSSH
  keeps the added ones in `/data/nerves_ssh`; it runs on the device only.
  """

  alias Kuroneko.{Auth, LoginLimit}

  @doc "The SSH daemon's `:pwdfun`: the page's password, whatever the user name."
  @spec check_password(charlist(), charlist(), term(), term()) :: boolean() | :disconnect
  def check_password(_user, password, _peer, _state) do
    cond do
      not LoginLimit.allow?() ->
        :disconnect

      not Auth.password_set?() ->
        false

      Auth.verify(List.to_string(password)) ->
        true

      true ->
        LoginLimit.failed()
        false
    end
  end

  @doc """
  The keys that may log in: the line of each, its type, SHA256 fingerprint
  and comment, and whether it is built into the firmware, which only new
  firmware takes away.
  """
  @spec keys() :: [map()]
  def keys do
    built_in = Application.get_env(:nerves_ssh, :authorized_keys, [])

    for line <- nerves_ssh_keys(), {:ok, key} <- [describe(line)] do
      Map.put(key, :built_in, line in built_in)
    end
  end

  @doc "Adds the public keys in `text`, one per line, as in authorized_keys."
  @spec add_keys(String.t()) :: :ok | {:error, :invalid_key | :no_ssh}
  def add_keys(text) do
    with {:ok, lines} <- parse(text) do
      Enum.reduce_while(lines, :ok, fn line, :ok ->
        case nerves_ssh(:add_authorized_key, [line]) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Removes a key that was added, by its line."
  @spec remove_key(String.t()) :: :ok | {:error, :built_in | :no_ssh}
  def remove_key(line) do
    line = String.trim(line)

    if line in Application.get_env(:nerves_ssh, :authorized_keys, []),
      do: {:error, :built_in},
      else: nerves_ssh(:remove_authorized_key, [line])
  end

  @doc """
  The public keys in `text`, one per line; blank lines and comments left
  out. Any line that is not a key fails the whole text, as does a text
  without one.
  """
  @spec parse(String.t()) :: {:ok, [String.t()]} | {:error, :invalid_key}
  def parse(text) when is_binary(text) do
    lines =
      text
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    if lines != [] and Enum.all?(lines, &match?({:ok, _key}, describe(&1))),
      do: {:ok, lines},
      else: {:error, :invalid_key}
  end

  @doc "A key's type, SHA256 fingerprint and comment, from its line."
  @spec describe(String.t()) :: {:ok, map()} | {:error, :invalid_key}
  def describe(line) do
    case :ssh_file.decode(line, :auth_keys) do
      [{key, attributes}] ->
        {:ok,
         %{
           key: line,
           type: line |> String.split(" ", parts: 2) |> hd(),
           fingerprint: to_string(:ssh.hostkey_fingerprint(:sha256, key)),
           comment: to_string(Keyword.get(attributes, :comment, ""))
         }}

      _other ->
        {:error, :invalid_key}
    end
  catch
    _kind, _reason -> {:error, :invalid_key}
  end

  defp nerves_ssh_keys do
    case nerves_ssh(:configuration, []) do
      %{authorized_keys: keys} -> keys
      _other -> []
    end
  catch
    :exit, _reason -> []
  end

  defp nerves_ssh(function, args) do
    if Code.ensure_loaded?(NervesSSH),
      do: apply(NervesSSH, function, args),
      else: {:error, :no_ssh}
  end
end
