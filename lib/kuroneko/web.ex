defmodule Kuroneko.Web do
  @moduledoc """
  KVM web interface on port 80 and, for the microphone, HTTPS on 443: the
  viewer page, and

    * `/ws`: input, a WebSocket (see `Kuroneko.BrowserInput`)
    * `/video?codecs=h264,h265`: the video stream for WebCodecs, a WebSocket
      that the page opens with the codecs it decodes (see
      `Kuroneko.VideoSocket`)
    * `/audio`: the target's sound, a WebSocket (see
      `Kuroneko.AudioSocket`)
    * `/microphone`: the target's USB microphone, a WebSocket (see
      `Kuroneko.MicrophoneSocket`)
    * `GET /api/usb` and `POST /api/usb`: the USB devices the target sees,
      their settings (see `Kuroneko.USBSettings`; a POST takes changes)
      with the functions the gadget has, each by name (`instances`), the
      endpoints they take of those there are and what each kind takes
      (`endpoints`), and the formats the target uses
    * `POST /api/usb/addresses` `{"address": "10.55.0.1/24"}`: the USB
      network's IP addresses, null for the default (see `Kuroneko.USBNetwork`)
    * `POST /api/usb/network` `{"device_address": ..., "host_address":
      ...}`: the USB network's MAC addresses, null for the default (see
      `Kuroneko.Gadget.set_network_addresses/2`)
    * `GET /api/screen` and `POST /api/screen`: the LCD's settings (see
      `Kuroneko.Screen.check/1`; a POST takes changes)
    * `POST /api/wol` `{"mac": "aa:bb:cc:dd:ee:ff"}`: Wake-on-LAN
    * `POST /api/expansion/mode` `{"mode": "pwm_gpio"}`, `POST
      /api/expansion/gpio` `{"line": 0, "value": 1}` (`null` reads it as an
      input) and `POST /api/expansion/pwm` `{"line": 0, "period": ns,
      "duty_cycle": ns}` or `{"line": 0, "stop": true}`: the auxiliary
      port's expansion lines (see `NanoKVMGo.Expansion`)
    * `/status`: the video input, the USB functions and the NanoKVM's own
      CPU, memory and network use (`NanoKVMGo.Metrics`), for the viewer
    * `/device`: the device page, its hardware, status and settings, live
      (`KuronekoWeb.DeviceLive`, with its socket at `/live` and its assets
      at `/assets`); `GET /api/device`, all it shows (see
      `Kuroneko.DeviceInfo`), and
      `/api/device/live`, a WebSocket with what changes each second (see
      `Kuroneko.DeviceSocket`)
    * `GET /api/disk`: the virtual disk's library and drive (see
      `Kuroneko.VirtualDisk`); `POST /api/disk/insert` `{"name": ...,
      "media": "auto", "read_only": true}` for an image (`"cd"`, `"dvd"`,
      `"bd"` or `"drive"` force one), `{"name": ..., "filesystem":
      "exfat", "read_only": true}` (or `"fat32"`) for a folder, with
      `"drive": 1` for a drive other than the first empty one and
      `"remember": false` for it not to go in again after a restart, `POST
      /api/disk/eject` `{"drive": 1}`, `POST
      /api/disk/delete` `{"name": ...}`, `PUT /api/disk/files?name=...` with
      the file as the body (`folder/file` for a folder's files, `&replace=1`
      to replace one)
    * `POST /api/firmware/validate`: keeps the firmware on trial
    * `POST /api/reboot`
    * `/settings`: the settings page, Wi-Fi, SSH keys and the password;
      `GET /api/wifi`, the Wi-Fi's state and the networks in reach (see
      `Kuroneko.WiFi`; `?scan=1` scans again when the last scan is ten
      seconds old), `POST /api/wifi/scan`, `POST /api/wifi` `{"ssid":
      ..., "passphrase": ..., "hidden": false}` to join a network, `POST
      /api/wifi/forget`, `POST /api/wifi/country` `{"country": "JP"}`;
      `GET /api/ssh/keys`, `POST /api/ssh/keys` `{"key":
      ...}` (one or more lines) and `POST /api/ssh/keys/remove` `{"key":
      ...}` (see `Kuroneko.SSH`)

  MJPEG for other browsers comes from `NanoKVMGo.Video` on 8088. WebSockets,
  like the POSTs, take only requests from the page itself: browsers let any
  site open a WebSocket to the device, and say which in the origin.

  Everything but the page and logging in needs a session, which a password
  (`Kuroneko.Auth`) opens: `POST /api/auth/setup` `{"password": ...,
  "code": ...}` while there is none, with the code the LCD shows
  (`Kuroneko.SetupCode`), `POST /api/auth/login`, `POST /api/auth/logout`,
  `POST /api/auth/password` `{"current": ..., "password": ...}`. Without a
  session the page is the login page. With HTTPS running, HTTP sends
  browsers there.
  """

  alias Kuroneko.Auth
  alias Kuroneko.LoginLimit
  alias Kuroneko.SetupCode
  alias Kuroneko.USBSettings
  alias Kuroneko.VideoSettings
  use Plug.Router
  require Logger

  @network_fields %{"device_address" => :device_address, "host_address" => :host_address}
  @expansion_modes Map.new(
                     ~w(off uart gpio pwm pwm_gpio gpio_pwm i2c)a,
                     &{Atom.to_string(&1), &1}
                   )
  # What needs no session: the page (or the login page) and logging in.
  @public [
    {"GET", "/"},
    {"GET", "/device"},
    {"GET", "/settings"},
    {"GET", "/api/auth"},
    {"POST", "/api/auth/login"},
    {"POST", "/api/auth/setup"}
  ]

  @session_options [
    store: :cookie,
    key: "_kuroneko",
    signing_salt: "kuroneko session",
    same_site: "Strict",
    http_only: true,
    max_age: 30 * 24 * 3600
  ]

  @doc false
  # The LiveView socket reads the session from the same cookie.
  def session_options, do: @session_options

  plug(:https_only)
  plug(:put_secret_key_base)
  plug(Plug.Session, @session_options)

  plug(:fetch_session)
  plug(:authenticate)
  plug(:match)
  plug(:dispatch)

  # The LiveView pages' socket and assets (KuronekoWeb)
  match("/live/*_rest", do: phoenix(conn))
  get("/assets/*_rest", do: phoenix(conn))

  get("/", do: page(conn, "index.html"))
  get("/device", do: if(logged_in?(conn), do: phoenix(conn), else: page(conn, "login.html")))
  get("/settings", do: page(conn, "settings.html"))
  get("/disk.js", do: asset(conn, "disk.js", "text/javascript"))
  get("/disk.css", do: asset(conn, "disk.css", "text/css"))

  get "/api/auth" do
    json(conn, 200, %{password_set: Auth.password_set?(), logged_in: logged_in?(conn)})
  end

  # The first password takes the code on the LCD: someone at the device
  # sets it, not whoever reaches the page first.
  post "/api/auth/setup" do
    with {:ok, %{"password" => password} = data, conn} when is_binary(password) <-
           page_json(conn),
         {:allowed, true} <- {:allowed, LoginLimit.allow?()},
         false <- Auth.password_set?(),
         {:code, true} <- {:code, SetupCode.check(data["code"])},
         :ok <- Auth.set_password(password) do
      conn |> start_session() |> json(200, %{ok: true})
    else
      {:allowed, false} ->
        json(conn, 429, %{error: "too many tries, wait a minute"})

      {:code, false} ->
        LoginLimit.failed()
        json(conn, 401, %{error: "wrong setup code: the screen shows a new one"})

      {:error, :too_short} ->
        json(conn, 400, %{error: "at least 8 characters"})

      true ->
        json(conn, 409, %{error: "a password is set"})

      other ->
        refused(conn, other)
    end
  end

  post "/api/auth/login" do
    with {:ok, %{"password" => password}, conn} when is_binary(password) <- page_json(conn),
         {:allowed, true} <- {:allowed, LoginLimit.allow?()} do
      if Auth.password_set?() and Auth.verify(password) do
        conn |> start_session() |> json(200, %{ok: true})
      else
        LoginLimit.failed()
        json(conn, 401, %{error: "wrong password"})
      end
    else
      {:allowed, false} -> json(conn, 429, %{error: "too many tries, wait a minute"})
      other -> refused(conn, other)
    end
  end

  post "/api/auth/logout" do
    conn |> configure_session(drop: true) |> json(200, %{ok: true})
  end

  post "/api/auth/password" do
    with {:ok, %{"current" => current, "password" => password}, conn} <- page_json(conn),
         {:current, true} <- {:current, is_binary(current) and Auth.verify(current)},
         true <- is_binary(password),
         :ok <- Auth.set_password(password) do
      conn |> start_session() |> json(200, %{ok: true})
    else
      {:current, false} -> json(conn, 401, %{error: "wrong password"})
      {:error, :too_short} -> json(conn, 400, %{error: "at least 8 characters"})
      other -> refused(conn, other)
    end
  end

  get("/ws", do: websocket(conn, Kuroneko.InputSocket))

  get "/video" do
    conn = fetch_query_params(conn)

    websocket(
      conn,
      Kuroneko.VideoSocket,
      Kuroneko.VideoSocket.codecs(conn.query_params["codecs"])
    )
  end

  get("/audio", do: websocket(conn, Kuroneko.AudioSocket))
  get("/microphone", do: websocket(conn, Kuroneko.MicrophoneSocket))
  get("/api/device/live", do: websocket(conn, Kuroneko.DeviceSocket))

  get("/api/device", do: json(conn, 200, Kuroneko.DeviceInfo.overview()))

  # Ends the firmware's trial: after a reboot the device stays on it.
  post "/api/firmware/validate" do
    if same_origin?(conn) and json?(conn) do
      validate =
        Application.get_env(:kuroneko, :validate, &Nerves.Runtime.validate_firmware/0)

      case validate.() do
        :ok -> json(conn, 200, %{validated: true})
        {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
      end
    else
      send_resp(conn, 403, "forbidden")
    end
  end

  get("/api/usb", do: json(conn, 200, usb()))

  # The USB network's IP address: the page may have come over that network,
  # which moves, so the reply leaves first.
  post "/api/usb/addresses" do
    with {:ok, %{"address" => address}, conn} when is_binary(address) or is_nil(address) <-
           page_json(conn),
         :ok <- usb_network().check(address) do
      conn
      |> json(202, %{address: address})
      |> after_reply(fn -> usb_network().set(address) end, "USB network addresses not set")
    else
      {:error, reason} when is_atom(reason) -> json(conn, 400, %{error: reason})
      other -> refused(conn, other)
    end
  end

  # The USB network's MAC addresses, `{"host_address": "02:12:34:56:78:9a"}`:
  # null is the default, a field left out stays. The change takes the USB
  # network away for a moment, and the page may be on it: the reply leaves
  # first.
  post "/api/usb/network" do
    server = Application.get_env(:kuroneko, :usb_server, Kuroneko.Gadget)

    with {:ok, data, conn} <- page_json(conn),
         {:ok, settings} <- network_settings(data),
         :ok <- Kuroneko.Gadget.validate_network_addresses(server, settings) do
      conn
      |> json(202, %{changing: true})
      |> after_reply(
        fn -> Kuroneko.Gadget.set_network_addresses(server, settings) end,
        "USB network addresses #{inspect(settings)} not set"
      )
    else
      {:error, {reason, field, _value}} when reason in [:invalid_address, :multicast_address] ->
        json(conn, 400, %{error: reason, field: field})

      {:error, reason} when reason in [:same_addresses, :no_default_addresses] ->
        json(conn, 400, %{error: reason})

      {:error, reason} when not is_struct(reason) ->
        json(conn, 503, %{error: inspect(reason)})

      other ->
        refused(conn, other)
    end
  end

  # Changes take the USB devices off the target for a moment.
  post "/api/usb" do
    with {:page, true} <- {:page, same_origin?(conn) and json?(conn)},
         {:ok, body, conn} <- read_body(conn, length: 10_000),
         {:ok, changes} when is_map(changes) <- Jason.decode(body),
         {:ok, _settings} <- USBSettings.merge(USBSettings.saved(), changes) do
      case USBSettings.update(changes) do
        {:ok, _settings} ->
          json(conn, 200, usb())

        {:error, {:not_enough_endpoints, counts}} ->
          json(conn, 409, Map.put(counts, :error, :not_enough_endpoints))

        {:error, reason} ->
          json(conn, 500, %{error: inspect(reason)})
      end
    else
      {:page, false} -> send_resp(conn, 403, "forbidden")
      {:error, reason} when not is_struct(reason) -> json(conn, 400, usb_error(reason))
      _ -> send_resp(conn, 400, "bad request")
    end
  end

  get("/api/video", do: json(conn, 200, video()))

  post "/api/video" do
    with {:ok, changes, conn} <- page_json(conn) do
      case VideoSettings.update(changes) do
        {:ok, _settings} -> json(conn, 200, video())
        {:error, {:invalid, setting}} -> json(conn, 400, %{error: :invalid, setting: setting})
        {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
      end
    else
      other -> refused(conn, other)
    end
  end

  # Reads the text in an area of the picture: x, y, width and height as
  # fractions of the picture's.
  post "/api/ocr" do
    with {:ok, data, conn} <- page_json(conn),
         {:ok, area} <- ocr_area(data) do
      case Kuroneko.OCR.read(area) do
        {:ok, lines} ->
          json(conn, 200, %{
            text: Enum.map_join(lines, "\n", & &1.text),
            lines: Enum.map(lines, &%{&1 | box: Tuple.to_list(&1.box)})
          })

        {:error, :unavailable} ->
          json(conn, 503, %{error: "text reading needs the NPU and its models"})

        {:error, reason} when reason in [:no_input, :timeout, :stopped] ->
          json(conn, 409, %{error: "no picture"})

        {:error, :empty_area} ->
          json(conn, 400, %{error: "empty area"})

        {:error, reason} ->
          json(conn, 500, %{error: inspect(reason)})
      end
    else
      other -> refused(conn, other)
    end
  end

  get "/api/screen" do
    case Kuroneko.Screen.settings() do
      {:ok, settings} -> json(conn, 200, settings)
      {:error, :no_screen} -> json(conn, 503, %{error: "no screen"})
    end
  end

  post "/api/screen" do
    with {:page, true} <- {:page, same_origin?(conn) and json?(conn)},
         {:ok, body, conn} <- read_body(conn, length: 1_000),
         {:ok, changes} when is_map(changes) <- Jason.decode(body),
         {:ok, settings} <- Kuroneko.Screen.update(changes) do
      json(conn, 200, settings)
    else
      {:page, false} -> send_resp(conn, 403, "forbidden")
      {:error, {:invalid, key}} -> json(conn, 400, %{error: "invalid #{key}"})
      {:error, :no_screen} -> json(conn, 503, %{error: "no screen"})
      {:error, reason} when not is_struct(reason) -> json(conn, 500, %{error: inspect(reason)})
      _ -> json(conn, 400, %{error: "bad request"})
    end
  end

  post "/api/expansion/mode" do
    with {:ok, data, conn} <- page_json(conn),
         {:ok, mode} <- Map.fetch(@expansion_modes, data["mode"]) do
      expansion(conn, &NanoKVMGo.Expansion.set_mode(&1, mode, []))
    else
      other -> refused(conn, other)
    end
  end

  post "/api/expansion/gpio" do
    with {:ok, %{"line" => line} = data, conn} when line in [0, 1] <- page_json(conn) do
      case data["value"] do
        nil -> expansion(conn, &NanoKVMGo.Expansion.read(&1, line))
        value when value in [0, 1] -> expansion(conn, &NanoKVMGo.Expansion.write(&1, line, value))
        _other -> refused(conn, :bad_request)
      end
    else
      other -> refused(conn, other)
    end
  end

  post "/api/expansion/pwm" do
    with {:ok, %{"line" => line} = data, conn} when line in [0, 1] <- page_json(conn) do
      case data do
        %{"stop" => true} ->
          expansion(conn, &NanoKVMGo.Expansion.stop_pwm(&1, line))

        %{"period" => period, "duty_cycle" => duty}
        when period in 1_000..10_000_000_000 and is_integer(duty) and duty >= 0 and duty <= period ->
          expansion(conn, &NanoKVMGo.Expansion.set_pwm(&1, line, period, duty))

        _other ->
          refused(conn, :bad_request)
      end
    else
      other -> refused(conn, other)
    end
  end

  post "/api/wol" do
    with {:page, true} <- {:page, same_origin?(conn) and json?(conn)},
         {:ok, body, conn} <- read_body(conn, length: 1_000),
         {:ok, %{"mac" => text}} when is_binary(text) <- Jason.decode(body),
         {:ok, mac} <- Kuroneko.WakeOnLan.parse_mac(text) do
      case Kuroneko.WakeOnLan.wake(mac) do
        :ok -> json(conn, 200, %{sent: text})
        {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
      end
    else
      {:page, false} -> send_resp(conn, 403, "forbidden")
      _ -> json(conn, 400, %{error: "not a MAC address"})
    end
  end

  get "/api/wifi" do
    conn = fetch_query_params(conn)
    json(conn, 200, wifi().overview(scan: conn.query_params["scan"] == "1"))
  end

  post "/api/wifi/scan" do
    with {:ok, _data, conn} <- page_json(conn) do
      case wifi().scan() do
        :ok -> json(conn, 202, %{scanning: true})
        {:error, reason} -> json(conn, 503, %{error: wifi_error(reason)})
      end
    else
      other -> refused(conn, other)
    end
  end

  # Joining another network takes away the one the page may have come over:
  # the reply leaves first.
  post "/api/wifi" do
    with {:ok, %{"ssid" => ssid} = data, conn} when is_binary(ssid) <- page_json(conn),
         passphrase when is_binary(passphrase) or is_nil(passphrase) <- data["passphrase"],
         {:ok, config} <- wifi().config(ssid, passphrase, hidden: data["hidden"] == true) do
      conn
      |> json(202, %{joining: ssid})
      |> after_reply(fn -> wifi().apply_config(config) end, "Wi-Fi network not joined")
    else
      {:error, reason} when is_atom(reason) -> json(conn, 400, %{error: wifi_error(reason)})
      other -> refused(conn, other)
    end
  end

  post "/api/wifi/forget" do
    with {:ok, _data, conn} <- page_json(conn) do
      conn
      |> json(202, %{forgetting: true})
      |> after_reply(fn -> wifi().forget() end, "Wi-Fi network not forgotten")
    else
      other -> refused(conn, other)
    end
  end

  # Pairing stays open 2 minutes, or until closed.
  post "/api/bluetooth/pairing" do
    with {:ok, %{"open" => open}, conn} when is_boolean(open) <- page_json(conn) do
      bluetooth_reply(conn, fn ->
        if open,
          do: NanoKVMGo.Bluetooth.open_pairing(120),
          else: NanoKVMGo.Bluetooth.close_pairing()
      end)
    else
      other -> refused(conn, other)
    end
  end

  post "/api/bluetooth/forget" do
    with {:ok, %{"address" => address}, conn} when is_binary(address) <- page_json(conn),
         true <- address =~ ~r/^([0-9A-F]{2}:){5}[0-9A-F]{2}$/ do
      bluetooth_reply(conn, fn -> NanoKVMGo.Bluetooth.forget(address) end)
    else
      other -> refused(conn, other)
    end
  end

  # The Wi-Fi restarts with the country's rules: the reply leaves first.
  post "/api/wifi/country" do
    with {:ok, %{"country" => code}, conn} <- page_json(conn),
         {:ok, code} <- wifi().country_code(code) do
      conn
      |> json(202, %{country: code})
      |> after_reply(fn -> wifi().set_country(code) end, "Wi-Fi country not set")
    else
      {:error, reason} when is_atom(reason) -> json(conn, 400, %{error: wifi_error(reason)})
      other -> refused(conn, other)
    end
  end

  get("/api/disk", do: json(conn, 200, disk().state()))

  post "/api/disk/insert" do
    with {:ok, %{"name" => name} = data, conn} when is_binary(name) <- page_json(conn),
         :ok <- disk().insert(name, disk_options(data)) do
      json(conn, 202, %{inserting: name})
    else
      {:error, reason} -> disk_refused(conn, reason)
      other -> refused(conn, other)
    end
  end

  post "/api/disk/eject" do
    with {:ok, data, conn} <- page_json(conn),
         drive = if(is_integer(data["drive"]), do: data["drive"], else: 0),
         :ok <- disk().eject(drive) do
      json(conn, 202, %{ejecting: true})
    else
      {:error, reason} -> disk_refused(conn, reason)
      other -> refused(conn, other)
    end
  end

  post "/api/disk/delete" do
    with {:ok, %{"name" => name}, conn} when is_binary(name) <- page_json(conn),
         :ok <- disk().delete(name) do
      json(conn, 200, %{deleted: name})
    else
      {:error, reason} -> disk_refused(conn, reason)
      other -> refused(conn, other)
    end
  end

  # The body is the file, gigabytes for an ISO: it goes to disk as it comes.
  put "/api/disk/files" do
    conn = fetch_query_params(conn)
    name = conn.query_params["name"]

    with {:page, true} <- {:page, same_origin?(conn)},
         {:ok, final, temporary} <-
           disk().upload_paths(name, replace: conn.query_params["replace"] == "1"),
         {:ok, conn} <- receive_file(conn, temporary),
         :ok <- disk().finish_upload(temporary, final) do
      json(conn, 201, %{uploaded: name})
    else
      {:page, false} -> send_resp(conn, 403, "forbidden")
      {:error, reason} -> disk_refused(conn, reason)
    end
  end

  get("/api/ssh/keys", do: json(conn, 200, %{keys: ssh().keys()}))

  post "/api/ssh/keys" do
    with {:ok, %{"key" => text}, conn} when is_binary(text) <- page_json(conn) do
      case ssh().add_keys(text) do
        :ok -> json(conn, 200, %{keys: ssh().keys()})
        {:error, :invalid_key} -> json(conn, 400, %{error: "not a public key: one per line"})
        {:error, reason} -> json(conn, 503, %{error: inspect(reason)})
      end
    else
      other -> refused(conn, other)
    end
  end

  post "/api/ssh/keys/remove" do
    with {:ok, %{"key" => line}, conn} when is_binary(line) <- page_json(conn) do
      case ssh().remove_key(line) do
        :ok -> json(conn, 200, %{keys: ssh().keys()})
        {:error, :built_in} -> json(conn, 400, %{error: "built into the firmware"})
        {:error, reason} -> json(conn, 503, %{error: inspect(reason)})
      end
    else
      other -> refused(conn, other)
    end
  end

  get "/status" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        hid: Kuroneko.Gadget.Input.stats(),
        usb: Kuroneko.Gadget.functions(),
        storage: storage_status(),
        video: %{input: NanoKVMGo.Video.input(), capture: NanoKVMGo.Video.capture_stats()},
        audio: %{
          format: NanoKVMGo.Audio.format(),
          mode: USBSettings.mode(Kuroneko.Gadget.functions())
        },
        mjpeg_token: Application.get_env(:kuroneko, :mjpeg_token),
        ocr: Kuroneko.OCR.available?(),
        bluetooth: Kuroneko.Bluetooth.status(),
        temperature: temperature(),
        metrics: metrics()
      })
    )
  end

  defp metrics do
    NanoKVMGo.Metrics.current()
  catch
    :exit, {:noproc, _call} -> nil
  end

  defp temperature do
    case NanoKVMGo.temperature() do
      {:ok, celsius} -> celsius
      {:error, _reason} -> nil
    end
  end

  # Same-origin JSON only, so that another site open in the browser cannot
  # restart the device with a form or a fetch.
  post "/api/reboot" do
    if same_origin?(conn) and json?(conn) do
      reboot = Application.get_env(:kuroneko, :reboot, &Nerves.Runtime.reboot/0)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(202, Jason.encode!(%{rebooting: true}))
      |> after_reply(reboot, "not restarted")
    else
      send_resp(conn, 403, "forbidden")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # A page, or the login page without a session; logging in reloads it.
  defp page(conn, page) do
    page = if logged_in?(conn), do: page, else: "login.html"

    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:kuroneko, "priv/static/" <> page))
  end

  # What the pages share, for a session only.
  defp asset(conn, file, type) do
    conn
    |> put_resp_content_type(type)
    |> send_file(200, Application.app_dir(:kuroneko, "priv/static/" <> file))
  end

  defp https_only(%{scheme: :http, method: "GET"} = conn, _opts) do
    if Application.get_env(:kuroneko, :https_redirect, false) do
      conn
      |> put_resp_header("location", "https://#{conn.host}#{conn.request_path}")
      |> send_resp(301, "")
      |> halt()
    else
      conn
    end
  end

  defp https_only(conn, _opts), do: conn

  defp put_secret_key_base(conn, _opts), do: %{conn | secret_key_base: Auth.secret()}

  defp phoenix(conn), do: KuronekoWeb.Endpoint.call(conn, KuronekoWeb.Endpoint.init([]))

  defp authenticate(conn, _opts) do
    if {conn.method, conn.request_path} in @public or
         String.starts_with?(conn.request_path, "/assets/") or logged_in?(conn),
       do: conn,
       else: conn |> json(401, %{error: "log in first"}) |> halt()
  end

  defp logged_in?(conn) do
    Auth.password_set?() and get_session(conn, "generation") == Auth.generation()
  end

  defp start_session(conn) do
    conn |> configure_session(renew: true) |> put_session("generation", Auth.generation())
  end

  # The object a same-origin JSON POST sends.
  defp page_json(conn) do
    with {:page, true} <- {:page, same_origin?(conn) and json?(conn)},
         {:ok, body, conn} <- read_body(conn, length: 10_000),
         {:ok, data} when is_map(data) <- Jason.decode(body) do
      {:ok, data, conn}
    end
  end

  defp ocr_area(%{"x" => x, "y" => y, "width" => w, "height" => h})
       when is_number(x) and is_number(y) and is_number(w) and is_number(h) and w > 0 and h > 0,
       do: {:ok, %{x: x, y: y, width: w, height: h}}

  defp ocr_area(_data), do: :error

  defp bluetooth_reply(conn, change) do
    case change.() do
      :ok -> json(conn, 200, Kuroneko.Bluetooth.status())
      {:error, reason} -> json(conn, 409, %{error: inspect(reason)})
    end
  catch
    :exit, _not_running -> json(conn, 503, %{error: "Bluetooth is not running"})
  end

  defp refused(conn, {:page, false}), do: send_resp(conn, 403, "forbidden")
  defp refused(conn, _other), do: send_resp(conn, 400, "bad request")

  # A change that moves the network the page came over comes once the reply
  # is sent; the page takes a reply lost on the way as the change underway.
  defp after_reply(conn, change, failure) do
    with {:error, reason} <- change.(), do: Logger.error("#{failure}: #{inspect(reason)}")
    conn
  end

  defp wifi, do: Application.get_env(:kuroneko, :wifi, Kuroneko.WiFi)
  defp disk, do: Application.get_env(:kuroneko, :virtual_disk, Kuroneko.VirtualDisk)
  defp usb_network, do: Application.get_env(:kuroneko, :usb_network, Kuroneko.USBNetwork)

  @disk_choices %{
    "media" => %{"auto" => :auto, "cd" => :cd, "dvd" => :dvd, "bd" => :bd, "drive" => :drive},
    "filesystem" => %{"exfat" => :exfat, "fat32" => :fat32}
  }

  defp disk_options(data) do
    choices =
      for {field, values} <- @disk_choices,
          value = values[data[field]],
          value != nil,
          do: {String.to_existing_atom(field), value}

    flags =
      for key <- [:read_only, :remember], is_boolean(data["#{key}"]), do: {key, data["#{key}"]}

    drive =
      if is_integer(data["drive"]) and data["drive"] >= 0, do: [drive: data["drive"]], else: []

    made = for key <- [:maker, :mode], is_binary(data["#{key}"]), do: {key, data["#{key}"]}

    drive ++ choices ++ flags ++ made
  end

  # The page explains the reasons it knows.
  defp disk_refused(conn, reason) when is_atom(reason) do
    status =
      case reason do
        r when r in [:busy, :in_use, :exists, :eject_first] -> 409
        :no_drive -> 404
        r when r in [:invalid_name, :file_too_large, :cd_only, :not_offered] -> 400
        :no_maker -> 404
        :enoent -> 404
        :no_room -> 507
        r when r in [:no_storage, :no_exfat, :disc_unsupported, :tracks_unsupported] -> 503
        _other -> 500
      end

    json(conn, status, %{error: reason})
  end

  defp disk_refused(conn, {:bad_name, name}), do: json(conn, 400, %{error: :bad_name, name: name})

  defp disk_refused(conn, {:cue, detail}), do: json(conn, 400, %{error: :cue, detail: detail})

  defp disk_refused(conn, reason), do: json(conn, 500, %{error: inspect(reason)})

  defp receive_file(conn, path) do
    with {:ok, file} <- File.open(path, [:write, :binary, :raw]) do
      result =
        try do
          receive_into(conn, file)
        after
          File.close(file)
        end

      with {:error, _reason} <- result, do: File.rm(path)
      result
    end
  end

  defp receive_into(conn, file) do
    case read_body(conn, length: 4_000_000, read_length: 1_000_000, read_timeout: 60_000) do
      {:more, chunk, conn} -> with :ok <- :file.write(file, chunk), do: receive_into(conn, file)
      {:ok, chunk, conn} -> with :ok <- :file.write(file, chunk), do: {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ssh, do: Application.get_env(:kuroneko, :ssh, Kuroneko.SSH)

  defp wifi_error(:ssid_too_short), do: "the network needs a name"
  defp wifi_error(:ssid_too_long), do: "the name is longer than 32 bytes"
  defp wifi_error(:password_too_short), do: "the passphrase needs at least 8 characters"
  defp wifi_error(:password_too_long), do: "the passphrase is longer than 63 characters"
  defp wifi_error(:invalid_characters), do: "the passphrase takes ASCII characters only"
  defp wifi_error(:no_wifi), do: "this device has no Wi-Fi"
  defp wifi_error(:invalid_country), do: "not a country code"
  defp wifi_error(reason), do: inspect(reason)

  defp websocket(conn, handler, state \\ %{}) do
    if same_origin?(conn) do
      conn
      |> WebSockAdapter.upgrade(handler, state, timeout: 60_000)
      |> halt()
    else
      send_resp(conn, 403, "forbidden")
    end
  end

  defp usb do
    %{
      settings: USBSettings.saved(),
      functions: Kuroneko.Gadget.functions(),
      # Each function by name, and the endpoints they take of those there are.
      instances: Kuroneko.Gadget.instances(),
      endpoints: Map.put(Kuroneko.Gadget.endpoints_in_use(), :costs, endpoint_costs()),
      # What the target chose, while the streams run.
      formats: %{
        microphone: NanoKVMGo.Microphone.format(),
        speaker: NanoKVMGo.Audio.format(Kuroneko.Speaker)
      }
    }
  end

  defp video do
    settings = VideoSettings.saved()

    %{
      settings: settings,
      preset: VideoSettings.preset(settings),
      presets: VideoSettings.presets(),
      codec: stream_codec()
    }
  end

  # The codec the stream takes now, nil without the video process.
  defp stream_codec do
    NanoKVMGo.Video.codec()
  catch
    :exit, {:noproc, _call} -> nil
  end

  # What a function of each kind takes, so that the page counts as the
  # gadget does.
  defp endpoint_costs do
    Map.new(
      [:network, :keyboard, :mouse, :relative_mouse, :storage, :microphone, :speaker],
      fn kind ->
        {:ok, cost} = Kuroneko.Gadget.endpoints([kind])
        {kind, cost}
      end
    )
  end

  # The addresses the page sends: null or empty for the default.
  defp network_settings(data) do
    Enum.reduce_while(data, {:ok, []}, fn
      {field, value}, {:ok, settings}
      when is_map_key(@network_fields, field) and (is_binary(value) or is_nil(value)) ->
        value = if value in [nil, ""], do: :default, else: String.trim(value)
        {:cont, {:ok, [{@network_fields[field], value} | settings]}}

      _other, _settings ->
        {:halt, :bad_request}
    end)
  end

  defp expansion(conn, call) do
    server = Application.get_env(:kuroneko, :expansion_server, NanoKVMGo.Expansion)

    case call.(server) do
      :ok ->
        json(conn, 200, %{ok: true})

      {:ok, value} ->
        json(conn, 200, %{value: value})

      {:error, :busy} ->
        json(conn, 409, %{error: "busy"})

      {:error, {reason, line}} when reason in [:not_gpio, :not_pwm] ->
        json(conn, 409, %{error: reason, line: line})

      {:error, {:unknown_mode, _mode}} ->
        json(conn, 400, %{error: "unknown_mode"})

      {:error, reason} ->
        json(conn, 503, %{error: inspect(reason)})
    end
  catch
    :exit, {:noproc, _call} -> json(conn, 503, %{error: "not running"})
  end

  # The page explains these.
  defp usb_error({reason, direction, _detail}) when direction in [:microphone, :speaker],
    do: %{error: reason, direction: direction}

  defp usb_error({:invalid, setting}), do: %{error: :invalid, setting: setting}

  defp usb_error(reason), do: %{error: inspect(reason)}

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp same_origin?(conn) do
    case get_req_header(conn, "origin") do
      [origin] ->
        uri = URI.parse(origin)
        uri.host == conn.host and uri.port == conn.port

      _ ->
        false
    end
  end

  defp json?(conn) do
    match?(["application/json" <> _], get_req_header(conn, "content-type"))
  end

  defp storage_status() do
    case Kuroneko.Gadget.MassStorage.medium() do
      {:ok, medium} -> %{medium: medium}
      {:error, reason} -> %{error: inspect(reason)}
    end
  end
end

defmodule Kuroneko.InputSocket do
  @moduledoc false
  # The viewer's input goes to the USB devices, or after
  # {"type": "target", "target": "bluetooth"} to the Bluetooth ones.
  @behaviour WebSock

  @targets %{"usb" => Kuroneko.Gadget.Input, "bluetooth" => Kuroneko.Bluetooth.Input}

  @impl WebSock
  def init(_args), do: {:ok, %{input: Kuroneko.Gadget.Input}}

  @impl WebSock
  def handle_in({text, opcode: :text}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "target", "target" => target}} when is_map_key(@targets, target) ->
        {:ok, retarget(state, @targets[target])}

      {:ok, event} when is_map(event) ->
        Kuroneko.BrowserInput.handle(event, state.input)
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info(_message, state), do: {:ok, state}

  # Keys held when the browser goes away, or turns to the other target,
  # must not stay pressed.
  @impl WebSock
  def terminate(_reason, state) do
    Kuroneko.Gadget.Input.release_all(state.input)
  end

  defp retarget(%{input: input} = state, input), do: state

  defp retarget(state, input) do
    Kuroneko.Gadget.Input.release_all(state.input)
    %{state | input: input}
  end
end

defmodule Kuroneko.VideoSocket do
  @moduledoc """
  The video stream for the page's WebCodecs decoder. The page opens it with
  the codecs it decodes, `/video?codecs=h264,h265`: with the `"auto"` codec
  the stream takes H.265 while every viewer decodes it.

  Binary messages are a type, then the Annex B access unit: 1 an H.264
  delta, 2 an H.264 keyframe, 3 an H.265 delta, 4 an H.265 keyframe. After
  a codec change the first is a keyframe. Text messages, `{"input": ...}`,
  come when the video input changes. The socket closes, with 1011, when the
  video process stops: the page connects again to the one that follows.
  """
  @behaviour WebSock

  @codecs %{"h264" => :h264, "h265" => :h265}

  @doc "The codecs a page names, H.264 for one that names none."
  @spec codecs(String.t() | nil) :: [:h264 | :h265]
  def codecs(names) do
    names
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.flat_map(&List.wrap(@codecs[&1]))
    |> case do
      [] -> [:h264]
      codecs -> Enum.uniq(codecs)
    end
  end

  @impl WebSock
  def init(codecs) do
    case Kuroneko.Subscription.subscribe(
           NanoKVMGo.Video,
           &NanoKVMGo.Video.subscribe(&1, codecs: codecs)
         ) do
      {:ok, monitor, :ok} -> {:ok, %{video: monitor}}
      {:ok, _monitor, {:error, reason}} -> {:stop, :normal, {1011, "no video (#{reason})"}, %{}}
      _not_running -> {:stop, :normal, {1011, "no video"}, %{}}
    end
  end

  @impl WebSock
  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info({NanoKVMGo.Video, {codec, kind, au}}, state) do
    {:push, {:binary, [type(codec, kind), au]}, state}
  end

  def handle_info({NanoKVMGo.Video, {:input, input}}, state) do
    {:push, {:text, Jason.encode!(%{input: input})}, state}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{video: monitor} = state) do
    {:stop, :normal, {1011, "the video stream stopped"}, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  defp type(:h264, :delta), do: 1
  defp type(:h264, :key), do: 2
  defp type(:h265, :delta), do: 3
  defp type(:h265, :key), do: 4
end

defmodule Kuroneko.AudioSocket do
  @moduledoc """
  The target's sound for the browser: what it plays to the USB speaker,
  while it does, else the audio of its HDMI output.

  Text messages, `{"format": {"rate": 48000, "channels": 2, "source":
  "hdmi"}}`, come before the samples of a source and when its rate changes;
  binary messages are interleaved S16LE samples. The socket closes, with
  1011, when a process the sound comes through stops: the page connects
  again.
  """
  @behaviour WebSock

  alias Kuroneko.Subscription

  # The speaker counts as playing this long after its last samples.
  @usb_hold_ms 300

  # Every process it monitors is one the sound comes through.
  @impl WebSock
  def init(_args) do
    state = %{speaker: nil, current: nil, usb_seen: nil, formats: %{}}

    with {:ok, _hdmi, :ok} <-
           Subscription.subscribe(NanoKVMGo.Audio, &NanoKVMGo.Audio.subscribe/1),
         {:ok, _gadget, {:ok, kinds}} <-
           Subscription.subscribe(Kuroneko.Gadget, &Kuroneko.Gadget.subscribe/1),
         {:ok, state} <- speaker(state, :speaker in kinds) do
      {:ok, state}
    else
      _not_running -> {:stop, :normal, {1011, "no sound"}, state}
    end
  end

  @impl WebSock
  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info({NanoKVMGo.Audio, {:format, source, format}}, state) do
    state = put_in(state.formats[source], format)

    if state.current == source,
      do: {:push, format_frame(source, format), state},
      else: {:ok, state}
  end

  def handle_info({NanoKVMGo.Audio, {:pcm, :usb, pcm}}, state) do
    forward(:usb, pcm, %{state | usb_seen: now()})
  end

  def handle_info({NanoKVMGo.Audio, {:pcm, :hdmi, pcm}}, state) do
    if speaker_playing?(state), do: {:ok, state}, else: forward(:hdmi, pcm, state)
  end

  def handle_info({Kuroneko.Gadget, {:functions, kinds}}, state) do
    case speaker(state, :speaker in kinds) do
      {:ok, state} -> {:ok, state}
      _not_running -> {:stop, :normal, {1011, "the sound stopped"}, state}
    end
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state),
    do: {:stop, :normal, {1011, "the sound stopped"}, state}

  def handle_info(_message, state), do: {:ok, state}

  defp forward(source, pcm, %{current: source} = state), do: {:push, {:binary, pcm}, state}

  defp forward(source, pcm, state) do
    case state.formats do
      %{^source => format} ->
        {:push, [format_frame(source, format), {:binary, pcm}], %{state | current: source}}

      _ ->
        {:ok, state}
    end
  end

  defp speaker_playing?(%{usb_seen: nil}), do: false
  defp speaker_playing?(state), do: now() - state.usb_seen < @usb_hold_ms

  # Captures the speaker only while the gadget has one: without, the capture
  # would fail over and over.
  defp speaker(%{speaker: nil} = state, true) do
    with {:ok, monitor, :ok} <-
           Subscription.subscribe(Kuroneko.Speaker, &NanoKVMGo.Audio.subscribe/1),
         do: {:ok, %{state | speaker: monitor}}
  end

  defp speaker(%{speaker: monitor} = state, false) when monitor != nil do
    :ok = NanoKVMGo.Audio.unsubscribe(Kuroneko.Speaker)
    Process.demonitor(monitor, [:flush])
    {:ok, %{state | speaker: nil, usb_seen: nil}}
  end

  defp speaker(state, _present), do: {:ok, state}

  defp format_frame(source, format) do
    {:text, Jason.encode!(%{format: Map.put(format, :source, source)})}
  end

  defp now, do: System.monotonic_time(:millisecond)
end

defmodule Kuroneko.MicrophoneSocket do
  @moduledoc """
  The browser's microphone for the target's USB microphone, one browser at a
  time. Text messages to the browser, `{"format": {"rate": 48000,
  "channels": 2, "sample_format": "s16_le"}}`, tell the format to send: the
  one the microphone was set up with, at the rate the target chose, again
  when it chooses another. Binary messages from the browser are interleaved
  samples in that format. The socket closes, with 1008, when the sound card
  drops the microphone, and with 1011 when a process the sound goes through
  stops.
  """
  @behaviour WebSock

  alias Kuroneko.Subscription

  @sample_bytes %{s16_le: 2, s24_3le: 3, s24_le: 4, s32_le: 4}

  # Every process it monitors is one the sound goes through.
  @impl WebSock
  def init(_args) do
    with {:ok, _gadget, {:ok, kinds}} <-
           Subscription.subscribe(Kuroneko.Gadget, &Kuroneko.Gadget.subscribe/1),
         {:microphone, true} <- {:microphone, :microphone in kinds},
         {:register, true} <- {:register, register()},
         {:ok, _microphone, :ok} <-
           Subscription.subscribe(NanoKVMGo.Microphone, &NanoKVMGo.Microphone.subscribe/1) do
      {:ok, %{frame_bytes: nil}}
    else
      {:microphone, false} ->
        {:stop, :normal, {1008, "the USB microphone is off"}, nil}

      {:register, false} ->
        {:stop, :normal, {1008, "another browser is using the microphone"}, nil}

      _not_running ->
        {:stop, :normal, {1011, "no microphone"}, nil}
    end
  end

  # Whole frames in the format, the samples of an old one dropped.
  @impl WebSock
  def handle_in({pcm, opcode: :binary}, %{frame_bytes: bytes} = state)
      when is_integer(bytes) and rem(byte_size(pcm), bytes) == 0 do
    NanoKVMGo.Microphone.play(pcm)
    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info({NanoKVMGo.Microphone, {:format, format}}, state) do
    bytes = format.channels * @sample_bytes[format.sample_format]
    {:push, {:text, Jason.encode!(%{format: format})}, %{state | frame_bytes: bytes}}
  end

  def handle_info({Kuroneko.Gadget, {:functions, kinds}}, state) do
    if :microphone in kinds,
      do: {:ok, state},
      else: {:stop, :normal, {1008, "the USB microphone is off"}, state}
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, state),
    do: {:stop, :normal, {1011, "the microphone stopped"}, state}

  def handle_info(_message, state), do: {:ok, state}

  defp register do
    Process.register(self(), __MODULE__)
  rescue
    ArgumentError -> false
  end
end
