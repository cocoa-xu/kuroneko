defmodule Kuroneko.TLS do
  @moduledoc """
  The HTTPS server's certificate: self-signed, made on the first start and
  kept. Browsers give the microphone, WebCodecs and AudioWorklet only to
  secure pages; the browser asks once whether to trust this certificate.
  """
  require Logger

  @validity_days 3650

  @doc """
  The Bandit options for the certificate in `dir`, made first if missing.

  The server picks the cipher, ChaCha20-Poly1305 first: these cores have
  no AES instructions, and AES-GCM in software costs them about five times
  as much per byte of video.
  """
  @spec options(Path.t()) :: keyword()
  def options(dir \\ "/data/kuroneko/tls") do
    certfile = Path.join(dir, "cert.pem")
    keyfile = Path.join(dir, "key.pem")

    unless File.regular?(certfile) and File.regular?(keyfile) do
      Logger.info("kuroneko: making a self-signed certificate in #{dir}")
      make(certfile, keyfile)
    end

    [
      certfile: certfile,
      keyfile: keyfile,
      thousand_island_options: [
        transport_options: [ciphers: ciphers(), honor_cipher_order: true]
      ]
    ]
  end

  defp ciphers do
    (:ssl.cipher_suites(:default, :"tlsv1.3") ++ :ssl.cipher_suites(:default, :"tlsv1.2"))
    |> Enum.uniq()
    |> Enum.sort_by(&(&1.cipher != :chacha20_poly1305))
  end

  defp make(certfile, keyfile) do
    {:ok, hostname} = :inet.gethostname()
    hostname = to_string(hostname)
    names = Enum.uniq(["#{hostname}.local", hostname, "nerves.local", "localhost"])
    key = X509.PrivateKey.new_ec(:secp256r1)

    cert =
      X509.Certificate.self_signed(key, "/CN=#{hostname}.local",
        template: :server,
        validity: X509.Certificate.Validity.days_from_now(@validity_days),
        extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name(names)]
      )

    File.mkdir_p!(Path.dirname(certfile))
    write!(keyfile, X509.PrivateKey.to_pem(key), 0o600)
    write!(certfile, X509.Certificate.to_pem(cert), 0o644)
  end

  # Whole files or none, should the power go.
  defp write!(path, data, mode) do
    tmp = path <> ".tmp"
    File.write!(tmp, data)
    File.chmod!(tmp, mode)
    File.rename!(tmp, path)
  end
end
