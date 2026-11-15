defmodule Kuroneko.Migration do
  @moduledoc false
  # The application was nanokvm_hello: its state (the password, the TLS
  # certificate, the settings) moves to the new directory, and the old one
  # becomes a link to it, for the firmware before should the device go back
  # to it.

  require Logger

  @spec run(Path.t()) :: :ok | {:error, term()}
  def run(data \\ "/data") do
    old = Path.join(data, "nanokvm_hello")
    new = Path.join(data, "kuroneko")

    cond do
      not match?({:ok, %File.Stat{type: :directory}}, File.lstat(old)) -> :ok
      File.exists?(new) -> :ok
      true -> move(old, new)
    end
  end

  defp move(old, new) do
    with :ok <- File.rename(old, new),
         :ok <- File.ln_s(Path.basename(new), old) do
      Logger.info("kuroneko: moved #{old} to #{new}")
    end
  end
end
