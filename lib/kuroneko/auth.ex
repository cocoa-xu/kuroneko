defmodule Kuroneko.Auth do
  @moduledoc """
  The page's password and the secret that signs its session cookies, kept
  in `/data/kuroneko/auth.json`.

  The password is kept as a PBKDF2-SHA256 hash. Until one is set the page
  asks for one. Changing it ends the other sessions: each carries the
  generation of the password it logged in with.
  """

  @iterations 100_000
  @min_length 8

  @doc "Whether a password is set."
  @spec password_set?() :: boolean()
  def password_set?, do: Map.has_key?(read(), "hash")

  @doc "The generation of the password, which sessions carry."
  @spec generation() :: non_neg_integer()
  def generation, do: Map.get(read(), "generation", 0)

  @doc "Whether a password is the one set."
  @spec verify(String.t()) :: boolean()
  def verify(password) when is_binary(password) do
    case read() do
      %{"hash" => hash, "salt" => salt, "iterations" => iterations} ->
        Plug.Crypto.secure_compare(derive(password, decode(salt), iterations), decode(hash))

      _none ->
        false
    end
  end

  @doc """
  Sets the password, at least #{@min_length} characters, and ends the
  sessions of the one before.
  """
  @spec set_password(String.t()) :: :ok | {:error, :too_short | term()}
  def set_password(password) when is_binary(password) do
    if String.length(password) < @min_length do
      {:error, :too_short}
    else
      salt = :crypto.strong_rand_bytes(16)

      write(
        Map.merge(read(), %{
          "hash" => encode(derive(password, salt, @iterations)),
          "salt" => encode(salt),
          "iterations" => @iterations,
          "generation" => generation() + 1
        })
      )
    end
  end

  @doc "The secret that signs the session cookies, made on first use."
  @spec secret() :: binary()
  def secret do
    case read() do
      %{"secret" => secret} ->
        decode(secret)

      auth ->
        secret = :crypto.strong_rand_bytes(64)
        :ok = write(Map.put(auth, "secret", encode(secret)))
        secret
    end
  end

  defp derive(password, salt, iterations),
    do: :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)

  defp encode(bytes), do: Base.encode64(bytes)
  defp decode(text), do: Base.decode64!(text)

  defp read do
    with {:ok, json} <- File.read(path()),
         {:ok, auth} when is_map(auth) <- Jason.decode(json) do
      auth
    else
      _ -> %{}
    end
  end

  # Whole files or none, the key only for its owner.
  defp write(auth) do
    tmp = path() <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path())),
         :ok <- File.write(tmp, Jason.encode!(auth)),
         :ok <- File.chmod(tmp, 0o600) do
      File.rename(tmp, path())
    end
  end

  defp path do
    Application.get_env(:kuroneko, :auth_file, "/data/kuroneko/auth.json")
  end
end
