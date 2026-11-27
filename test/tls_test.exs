defmodule Kuroneko.TLSTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "makes a server certificate once and keeps it", %{tmp_dir: tmp_dir} do
    options = Kuroneko.TLS.options(tmp_dir)
    certfile = options[:certfile]
    keyfile = options[:keyfile]
    pem = File.read!(certfile)
    cert = X509.Certificate.from_pem!(pem)
    {:ok, hostname} = :inet.gethostname()

    assert {:Extension, _oid, _critical, names} =
             X509.Certificate.extension(cert, :subject_alt_name)

    assert {:dNSName, ~c"#{hostname}.local"} in names
    assert File.stat!(keyfile).mode |> Bitwise.band(0o777) == 0o600

    assert X509.PrivateKey.from_pem!(File.read!(keyfile))
           |> X509.PublicKey.derive() == X509.Certificate.public_key(cert)

    assert Kuroneko.TLS.options(tmp_dir) == options
    assert File.read!(certfile) == pem
  end

  test "a browser that prefers AES-GCM gets ChaCha20-Poly1305", %{tmp_dir: tmp_dir} do
    plug = fn conn, _ -> Plug.Conn.send_resp(conn, 200, "") end

    {:ok, server} =
      Bandit.start_link(
        [plug: plug, scheme: :https, ip: :loopback, port: 0, startup_log: false] ++
          Kuroneko.TLS.options(tmp_dir)
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    aes_first =
      Enum.sort_by(:ssl.cipher_suites(:default, :"tlsv1.3"), &(&1.cipher != :aes_128_gcm))

    {:ok, socket} =
      :ssl.connect(~c"127.0.0.1", port,
        verify: :verify_none,
        versions: [:"tlsv1.3"],
        ciphers: aes_first
      )

    assert {:ok, [selected_cipher_suite: %{cipher: :chacha20_poly1305}]} =
             :ssl.connection_information(socket, [:selected_cipher_suite])

    :ssl.close(socket)
  end
end
