defmodule Kuroneko.TLSTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "makes a server certificate once and keeps it", %{tmp_dir: tmp_dir} do
    [certfile: certfile, keyfile: keyfile] = Kuroneko.TLS.options(tmp_dir)
    pem = File.read!(certfile)
    cert = X509.Certificate.from_pem!(pem)
    {:ok, hostname} = :inet.gethostname()

    assert {:Extension, _oid, _critical, names} =
             X509.Certificate.extension(cert, :subject_alt_name)

    assert {:dNSName, ~c"#{hostname}.local"} in names
    assert File.stat!(keyfile).mode |> Bitwise.band(0o777) == 0o600

    assert X509.PrivateKey.from_pem!(File.read!(keyfile))
           |> X509.PublicKey.derive() == X509.Certificate.public_key(cert)

    assert Kuroneko.TLS.options(tmp_dir) == [certfile: certfile, keyfile: keyfile]
    assert File.read!(certfile) == pem
  end
end
