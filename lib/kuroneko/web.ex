defmodule Kuroneko.Web do
  @moduledoc """
  KVM web interface on port 80 and, for the microphone, HTTPS on 443: the
  viewer page, and

    * `/ws`: input, a WebSocket (see `Kuroneko.BrowserInput`)
    * `/h264`: H.264 for WebCodecs, a WebSocket (binary messages: 1 delta or
      2 keyframe, then the Annex B access unit; text messages:
      `{"input": ...}` when the video input changes)
    * `/audio`: the target's sound, a WebSocket (see
      `Kuroneko.AudioSocket`)
    * `/microphone`: the target's USB microphone, a WebSocket (see
      `Kuroneko.MicrophoneSocket`)
    * `GET /api/usb` and `POST /api/usb`: the USB devices the target sees,
      their settings (see `Kuroneko.USBSettings`; a POST takes changes)
      with the functions the gadget has and the formats the target uses
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
    * `/device`: the device page, its hardware, status and settings;
      `GET /api/device`, all it shows (see `Kuroneko.DeviceInfo`), and
      `/api/device/live`, a WebSocket with what changes each second (see
      `Kuroneko.DeviceSocket`)
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
  use Plug.Router
  require Logger

  # Time for the reply to leave before the device, or its USB network, goes
  # down.
  @reply_delay 500
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

  plug(:https_only)
  plug(:put_secret_key_base)

  plug(Plug.Session,
    store: :cookie,
    key: "_kuroneko",
    signing_salt: "kuroneko session",
    same_site: "Strict",
    http_only: true,
    max_age: 30 * 24 * 3600
  )

  plug(:fetch_session)
  plug(:authenticate)
  plug(:match)
  plug(:dispatch)

  get("/", do: page(conn, "index.html"))
  get("/device", do: page(conn, "device.html"))
  get("/settings", do: page(conn, "settings.html"))

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
  get("/h264", do: websocket(conn, Kuroneko.H264Socket))
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

  # The USB network's MAC addresses, `{"host_address": "02:12:34:56:78:9a"}`:
  # null is the default, a field left out stays. The reply leaves before the
  # change, which takes the USB network away for a moment: the page may be
  # on it.
  post "/api/usb/network" do
    server = Application.get_env(:kuroneko, :usb_server, Kuroneko.Gadget)

    with {:ok, data, conn} <- page_json(conn),
         {:ok, settings} <- network_settings(data),
         :ok <- Kuroneko.Gadget.validate_network_addresses(server, settings) do
      Task.start(fn ->
        Process.sleep(@reply_delay)

        with {:error, reason} <- Kuroneko.Gadget.set_network_addresses(server, settings) do
          Logger.error("USB network addresses #{inspect(settings)} not set: #{inspect(reason)}")
        end
      end)

      json(conn, 202, %{changing: true})
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
        {:ok, _settings} -> json(conn, 200, usb())
        {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
      end
    else
      {:page, false} -> send_resp(conn, 403, "forbidden")
      {:error, reason} when not is_struct(reason) -> json(conn, 400, usb_error(reason))
      _ -> send_resp(conn, 400, "bad request")
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
      later(fn -> wifi().apply_config(config) end, "Wi-Fi network not joined")
      json(conn, 202, %{joining: ssid})
    else
      {:error, reason} when is_atom(reason) -> json(conn, 400, %{error: wifi_error(reason)})
      other -> refused(conn, other)
    end
  end

  post "/api/wifi/forget" do
    with {:ok, _data, conn} <- page_json(conn) do
      later(fn -> wifi().forget() end, "Wi-Fi network not forgotten")
      json(conn, 202, %{forgetting: true})
    else
      other -> refused(conn, other)
    end
  end

  # The Wi-Fi restarts with the country's rules: the reply leaves first.
  post "/api/wifi/country" do
    with {:ok, %{"country" => code}, conn} <- page_json(conn),
         {:ok, code} <- wifi().country_code(code) do
      later(fn -> wifi().set_country(code) end, "Wi-Fi country not set")
      json(conn, 202, %{country: code})
    else
      {:error, reason} when is_atom(reason) -> json(conn, 400, %{error: wifi_error(reason)})
      other -> refused(conn, other)
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
        hid: Kuroneko.Gadget.HID.stats(),
        usb: Kuroneko.Gadget.functions(),
        storage: storage_status(),
        video: %{input: NanoKVMGo.Video.input(), capture: NanoKVMGo.Video.capture_stats()},
        audio: %{
          format: NanoKVMGo.Audio.format(),
          mode: USBSettings.mode(Kuroneko.Gadget.functions())
        },
        mjpeg_token: Application.get_env(:kuroneko, :mjpeg_token),
        temperature: temperature(),
        metrics: metrics()
      })
    )
  end

  defp metrics do
    NanoKVMGo.Metrics.current()
  catch
    :exit, _reason -> nil
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

      Task.start(fn ->
        Process.sleep(@reply_delay)
        reboot.()
      end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(202, Jason.encode!(%{rebooting: true}))
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

  defp authenticate(conn, _opts) do
    if {conn.method, conn.request_path} in @public or logged_in?(conn),
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

  defp refused(conn, {:page, false}), do: send_resp(conn, 403, "forbidden")
  defp refused(conn, _other), do: send_resp(conn, 400, "bad request")

  # After the reply has left.
  defp later(change, failure) do
    Task.start(fn ->
      Process.sleep(@reply_delay)
      with {:error, reason} <- change.(), do: Logger.error("#{failure}: #{inspect(reason)}")
    end)
  end

  defp wifi, do: Application.get_env(:kuroneko, :wifi, Kuroneko.WiFi)
  defp ssh, do: Application.get_env(:kuroneko, :ssh, Kuroneko.SSH)

  defp wifi_error(:ssid_too_short), do: "the network needs a name"
  defp wifi_error(:ssid_too_long), do: "the name is longer than 32 bytes"
  defp wifi_error(:password_too_short), do: "the passphrase needs at least 8 characters"
  defp wifi_error(:password_too_long), do: "the passphrase is longer than 63 characters"
  defp wifi_error(:invalid_characters), do: "the passphrase takes ASCII characters only"
  defp wifi_error(:no_wifi), do: "this device has no Wi-Fi"
  defp wifi_error(:invalid_country), do: "not a country code"
  defp wifi_error(reason), do: inspect(reason)

  defp websocket(conn, handler) do
    if same_origin?(conn) do
      conn
      |> WebSockAdapter.upgrade(handler, %{}, timeout: 60_000)
      |> halt()
    else
      send_resp(conn, 403, "forbidden")
    end
  end

  defp usb do
    %{
      settings: USBSettings.saved(),
      functions: Kuroneko.Gadget.functions(),
      # What the target chose, while the streams run.
      formats: %{
        microphone: NanoKVMGo.Microphone.format(),
        speaker: NanoKVMGo.Audio.format(Kuroneko.Speaker)
      }
    }
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
    :exit, _reason -> json(conn, 503, %{error: "not running"})
  end

  # The page explains these.
  defp usb_error({reason, direction, _detail}) when direction in [:microphone, :speaker],
    do: %{error: reason, direction: direction}

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
    case Kuroneko.Gadget.Storage.medium() do
      {:ok, medium} -> %{medium: medium}
      {:error, reason} -> %{error: inspect(reason)}
    end
  end
end

defmodule Kuroneko.InputSocket do
  @moduledoc false
  @behaviour WebSock

  @impl WebSock
  def init(state), do: {:ok, state}

  @impl WebSock
  def handle_in({text, opcode: :text}, state) do
    case Jason.decode(text) do
      {:ok, event} when is_map(event) -> Kuroneko.BrowserInput.handle(event)
      _ -> :ok
    end

    {:ok, state}
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info(_message, state), do: {:ok, state}

  # Keys held when the browser goes away must not stay pressed on the target.
  @impl WebSock
  def terminate(_reason, _state) do
    Kuroneko.Gadget.HID.release_all()
  end
end

defmodule Kuroneko.H264Socket do
  @moduledoc false
  @behaviour WebSock

  @impl WebSock
  def init(state) do
    case NanoKVMGo.Video.subscribe() do
      :ok -> {:ok, state}
      {:error, reason} -> {:stop, :normal, {1011, "no H.264 (#{reason})"}, state}
    end
  end

  @impl WebSock
  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info({NanoKVMGo.Video, {:h264, kind, au}}, state) do
    {:push, {:binary, [if(kind == :key, do: 2, else: 1), au]}, state}
  end

  def handle_info({NanoKVMGo.Video, {:input, input}}, state) do
    {:push, {:text, Jason.encode!(%{input: input})}, state}
  end

  def handle_info(_message, state), do: {:ok, state}
end

defmodule Kuroneko.AudioSocket do
  @moduledoc """
  The target's sound for the browser: what it plays to the USB speaker,
  while it does, else the audio of its HDMI output.

  Text messages, `{"format": {"rate": 48000, "channels": 2, "source":
  "hdmi"}}`, come before the samples of a source and when its rate changes;
  binary messages are interleaved S16LE samples.
  """
  @behaviour WebSock

  # The speaker counts as playing this long after its last samples.
  @usb_hold_ms 300
  # How often to look whether the speaker came or went with the audio mode.
  @check_ms 2_000

  @impl WebSock
  def init(_args) do
    :ok = NanoKVMGo.Audio.subscribe()
    {:ok, check_speaker(%{current: nil, speaker: false, usb_seen: nil, formats: %{}})}
  end

  @impl WebSock
  def handle_in(_frame, state), do: {:ok, state}

  @impl WebSock
  def handle_info({NanoKVMGo.Audio, source, {:format, format}}, state) do
    state = put_in(state.formats[source], format)

    if state.current == source,
      do: {:push, format_frame(source, format), state},
      else: {:ok, state}
  end

  def handle_info({NanoKVMGo.Audio, :usb, {:pcm, pcm}}, state) do
    forward(:usb, pcm, %{state | usb_seen: now()})
  end

  def handle_info({NanoKVMGo.Audio, :hdmi, {:pcm, pcm}}, state) do
    if speaker_playing?(state), do: {:ok, state}, else: forward(:hdmi, pcm, state)
  end

  def handle_info(:check_speaker, state), do: {:ok, check_speaker(state)}
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
  defp check_speaker(state) do
    Process.send_after(self(), :check_speaker, @check_ms)
    present = :speaker in Kuroneko.Gadget.functions()

    cond do
      present and not state.speaker ->
        :ok = NanoKVMGo.Audio.subscribe(Kuroneko.Speaker)
        %{state | speaker: true}

      state.speaker and not present ->
        :ok = NanoKVMGo.Audio.unsubscribe(Kuroneko.Speaker)
        %{state | speaker: false, usb_seen: nil}

      true ->
        state
    end
  end

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
  samples in that format. The socket closes when the sound card drops the
  microphone.
  """
  @behaviour WebSock

  @check_ms 2_000
  @sample_bytes %{s16_le: 2, s24_3le: 3, s24_le: 4, s32_le: 4}

  @impl WebSock
  def init(_args) do
    cond do
      not microphone?() ->
        {:stop, :normal, {1008, "the USB microphone is off"}, nil}

      not register() ->
        {:stop, :normal, {1008, "another browser is using the microphone"}, nil}

      true ->
        :ok = NanoKVMGo.Microphone.subscribe()
        Process.send_after(self(), :check, @check_ms)
        {:ok, %{frame_bytes: nil}}
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

  def handle_info(:check, state) do
    if microphone?() do
      Process.send_after(self(), :check, @check_ms)
      {:ok, state}
    else
      {:stop, :normal, {1008, "the USB microphone is off"}, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  defp microphone?, do: :microphone in Kuroneko.Gadget.functions()

  defp register do
    Process.register(self(), __MODULE__)
  rescue
    ArgumentError -> false
  end
end
