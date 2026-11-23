defmodule Kuroneko.WebTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Kuroneko.Auth
  alias Kuroneko.Web

  @moduletag :tmp_dir
  @password "correct horse"
  # Plug.Test requests go to http://www.example.com
  @page [{"origin", "http://www.example.com"}, {"content-type", "application/json"}]

  setup %{tmp_dir: tmp_dir} do
    test = self()
    Application.put_env(:kuroneko, :reboot, fn -> send(test, :rebooted) end)

    Application.put_env(:kuroneko, :validate, fn ->
      send(test, :validated)
      :ok
    end)

    Application.put_env(:kuroneko, :auth_file, Path.join(tmp_dir, "auth.json"))
    Kuroneko.LoginLimit.reset()

    on_exit(fn ->
      Application.delete_env(:kuroneko, :reboot)
      Application.delete_env(:kuroneko, :validate)
      Application.delete_env(:kuroneko, :auth_file)
    end)

    :ok = Auth.set_password(@password)
  end

  defp request(method, path, body \\ "", headers \\ [], session \\ true) do
    conn = conn(method, path, body)

    conn =
      Enum.reduce(headers, conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)

    conn =
      if session, do: init_test_session(conn, %{"generation" => Auth.generation()}), else: conn

    Web.call(conn, Web.init([]))
  end

  test "restarts on a same-origin JSON request" do
    assert request(:post, "/api/reboot", "{}", @page).status == 202
    assert_receive :rebooted, 2_000
  end

  test "refuses other origins, a missing origin and other content types" do
    for headers <- [
          [{"origin", "http://evil.example"}, {"content-type", "application/json"}],
          [{"origin", "http://www.example.com:8080"}, {"content-type", "application/json"}],
          [{"content-type", "application/json"}],
          [{"origin", "http://www.example.com"}, {"content-type", "text/plain"}]
        ] do
      assert request(:post, "/api/reboot", "{}", headers).status == 403
    end

    refute_receive :rebooted, 1_000
  end

  # Any site the browser has open can ask for a WebSocket to the device.
  test "WebSockets only for the page itself" do
    for path <- ["/ws", "/h264", "/audio", "/microphone", "/api/device/live"],
        headers <- [[{"origin", "http://evil.example"}], []] do
      assert request(:get, path, "", headers).status == 403, "#{path} #{inspect(headers)}"
    end
  end

  test "everything but the page and logging in needs a session" do
    for {method, path} <- [
          get: "/status",
          get: "/api/usb",
          get: "/api/screen",
          get: "/api/device",
          get: "/api/device/live",
          get: "/ws",
          post: "/api/reboot",
          post: "/api/firmware/validate",
          post: "/api/auth/password",
          get: "/api/wifi",
          post: "/api/wifi",
          post: "/api/wifi/scan",
          post: "/api/wifi/forget",
          post: "/api/wifi/country",
          get: "/api/disk",
          post: "/api/disk/insert",
          post: "/api/disk/eject",
          post: "/api/disk/delete",
          put: "/api/disk/files",
          post: "/api/usb/addresses",
          get: "/api/ssh/keys",
          post: "/api/ssh/keys",
          post: "/api/ssh/keys/remove",
          get: "/disk.js",
          get: "/disk.css"
        ] do
      assert request(method, path, "{}", @page, false).status == 401, "#{method} #{path}"
    end

    login_page = request(:get, "/", "", [], false)
    assert login_page.status == 200
    assert login_page.resp_body =~ "Log in to control the computer"

    assert request(:get, "/", "", [], true).resp_body =~ ~s(id="canvas")

    # Logging in on the device page reloads it.
    assert request(:get, "/device", "", [], false).resp_body =~ "Log in to control the computer"
    assert request(:get, "/device").resp_body =~ ~s(<main id="device")
    assert request(:get, "/settings", "", [], false).resp_body =~ "Log in to control the computer"
    assert request(:get, "/settings").resp_body =~ ~s(<main id="settings")

    for {path, type} <- [{"/disk.js", "text/javascript"}, {"/disk.css", "text/css"}] do
      asset = request(:get, path)
      assert asset.status == 200
      assert [content_type] = get_resp_header(asset, "content-type")
      assert String.starts_with?(content_type, type)
    end

    refute_receive :rebooted, 100
  end

  test "logging in opens a session; five wrong passwords close it for a minute" do
    wrong = Jason.encode!(%{password: "wrong password"})
    right = Jason.encode!(%{password: @password})

    assert request(:post, "/api/auth/login", wrong, @page, false).status == 401
    conn = request(:post, "/api/auth/login", right, @page, false)
    assert conn.status == 200
    assert get_session(conn, "generation") == Auth.generation()

    for _ <- 1..5, do: request(:post, "/api/auth/login", wrong, @page, false)
    assert request(:post, "/api/auth/login", right, @page, false).status == 429
  end

  test "a password is set once, then changed with the current one" do
    setup = Jason.encode!(%{password: "another one"})
    assert request(:post, "/api/auth/setup", setup, @page, false).status == 409

    wrong = Jason.encode!(%{current: "nope", password: "a new password"})
    assert request(:post, "/api/auth/password", wrong, @page).status == 401

    short = Jason.encode!(%{current: @password, password: "short"})
    assert request(:post, "/api/auth/password", short, @page).status == 400

    before = Auth.generation()
    right = Jason.encode!(%{current: @password, password: "a new password"})
    assert request(:post, "/api/auth/password", right, @page).status == 200
    assert Auth.generation() == before + 1
    assert Auth.verify("a new password")
  end

  test "the first password takes the code the screen shows" do
    File.rm!(Application.fetch_env!(:kuroneko, :auth_file))
    setup = &Jason.encode!(%{password: &1, code: &2})

    assert request(:post, "/api/auth/setup", setup.("a new password", "000 000x"), @page, false).status ==
             401

    assert request(
             :post,
             "/api/auth/setup",
             Jason.encode!(%{password: "a new password"}),
             @page,
             false
           ).status ==
             401

    refute Auth.password_set?()

    code = Kuroneko.SetupCode.current()
    assert request(:post, "/api/auth/setup", setup.("short", code), @page, false).status == 400

    conn = request(:post, "/api/auth/setup", setup.("a new password", code), @page, false)
    assert conn.status == 200
    assert get_session(conn, "generation") == Auth.generation()
    assert Auth.verify("a new password")
    assert Kuroneko.SetupCode.current() == nil
  end

  test "five wrong setup codes close the setup for a minute" do
    File.rm!(Application.fetch_env!(:kuroneko, :auth_file))
    wrong = Jason.encode!(%{password: "a new password", code: "x"})
    for _ <- 1..5, do: request(:post, "/api/auth/setup", wrong, @page, false)

    right = Jason.encode!(%{password: "a new password", code: Kuroneko.SetupCode.current()})
    assert request(:post, "/api/auth/setup", right, @page, false).status == 429
    refute Auth.password_set?()
  end

  test "Wake-on-LAN only from the page, and only for a MAC address" do
    json_only = [{"content-type", "application/json"}]
    assert request(:post, "/api/wol", ~s({"mac":"aa:bb:cc:dd:ee:ff"}), json_only).status == 403
    assert request(:post, "/api/wol", ~s({"mac":"aa:bb"}), @page).status == 400
    assert request(:post, "/api/wol", ~s({"host":"x"}), @page).status == 400
  end

  test "screen settings only from the page, only ones the screen takes" do
    json_only = [{"content-type", "application/json"}]
    assert request(:post, "/api/screen", ~s({"brightness":50}), json_only).status == 403

    for body <- [
          ~s({"brightness":0}),
          ~s({"rotate":90}),
          ~s({"sleep":"never"}),
          ~s({"pwm_frequency":0}),
          ~s({"pwm_frequency":2000000}),
          ~s({"calibration":[1,0,0,0,1,0]}),
          ~s({"volume":1}),
          ~s([1])
        ] do
      assert request(:post, "/api/screen", body, @page).status == 400, body
    end

    # On the host there is no screen.
    assert request(:post, "/api/screen", ~s({"brightness":50,"calibration":null}), @page).status ==
             503

    assert request(:get, "/api/screen").status == 503
  end

  test "the device as JSON: on the host, without its hardware and processes" do
    conn = request(:get, "/api/device")
    assert conn.status == 200

    assert %{
             "hostname" => hostname,
             "hardware" => %{"compatible" => _, "cpu" => _},
             "components" => [%{"id" => "video_bridge"} | _],
             "storage" => %{"card" => nil, "partitions" => []},
             "firmware" => %{"active" => "a", "slots" => [%{"slot" => "a", "active" => true}]},
             "software" => %{"app" => _, "elixir" => _, "otp" => _},
             "status" => %{
               "video" => %{"input" => nil},
               "usb" => %{"connection" => nil, "functions" => nil, "network" => nil},
               "screen" => nil,
               "expansion" => nil,
               "network" => %{},
               "beam" => %{"processes" => processes},
               "trial" => %{"validated" => _, "revert_in" => nil}
             },
             "metrics" => %{"current" => nil, "history" => nil}
           } = Jason.decode!(conn.resp_body)

    assert is_binary(hostname) and processes > 0
  end

  test "keeps the firmware on a same-origin JSON request only" do
    json_only = [{"content-type", "application/json"}]
    assert request(:post, "/api/firmware/validate", "{}", json_only).status == 403
    refute_receive :validated, 100

    assert request(:post, "/api/firmware/validate", "{}", @page).status == 200
    assert_receive :validated
  end

  test "USB settings only from the page, and only ones the USB functions take" do
    json_only = [{"content-type", "application/json"}]
    origin_only = [{"origin", "http://www.example.com"}]

    assert request(:post, "/api/usb", ~s({"audio":"duplex"}), json_only).status == 403
    assert request(:post, "/api/usb", ~s({"audio":"duplex"}), origin_only).status == 403
    assert request(:post, "/api/usb", ~s({"audio":"loud"}), @page).status == 400
    assert request(:post, "/api/usb", ~s({"volume":11}), @page).status == 400

    invalid = request(:post, "/api/usb", ~s({"networks":["usb0"]}), @page)
    assert invalid.status == 400
    assert Jason.decode!(invalid.resp_body) == %{"error" => "invalid", "setting" => "networks"}

    bad_format = request(:post, "/api/usb", ~s({"microphone":{"rates":[]}}), @page)
    assert bad_format.status == 400

    assert %{"error" => "invalid_rates", "direction" => "microphone"} =
             Jason.decode!(bad_format.resp_body)

    assert request(:post, "/api/usb", ~s({"microphone":{"sample_bits":20}}), @page).status == 400
    assert request(:post, "/api/usb", ~s([1]), @page).status == 400
    assert request(:post, "/api/usb", "audio=duplex", @page).status == 400
  end

  describe "the USB network's MAC addresses" do
    defmodule KV do
      # Nerves.Runtime.KV: tells the test what is kept.
      def put(variables) do
        send(__MODULE__, {__MODULE__, variables})
        :ok
      end
    end

    # A gadget as the NanoKVM-Go system sets it up, with its own Kuroneko.Gadget.
    setup %{tmp_dir: tmp_dir} do
      gadget = Path.join(tmp_dir, "gadget")
      udc_class = Path.join(tmp_dir, "udc")
      ncm = Path.join(gadget, "functions/ncm.usb0")
      File.mkdir_p!(ncm)
      File.mkdir_p!(Path.join(gadget, "configs/c.1"))
      File.mkdir_p!(Path.join(udc_class, "udc.0"))
      File.ln_s!(ncm, Path.join(gadget, "configs/c.1/ncm.usb0"))
      File.write!(Path.join(gadget, "UDC"), "udc.0\n")
      File.write!(Path.join(ncm, "dev_addr"), "9e:9f:51:11:f7:b2\0\n")
      File.write!(Path.join(ncm, "host_addr"), "7a:78:1f:1f:1d:dd\0\n")

      options = NanoKVMGo.USB.gadget_options(serial_number: "0123456789abcdef", kv: KV)

      start_supervised!(
        {Kuroneko.Gadget,
         Keyword.merge(options, name: __MODULE__.USB, gadget: gadget, udc_class: udc_class)}
      )

      Process.register(self(), KV)
      Application.put_env(:kuroneko, :usb_server, __MODULE__.USB)
      on_exit(fn -> Application.delete_env(:kuroneko, :usb_server) end)
      %{ncm: ncm}
    end

    test "change after the reply, only from the page, only to unicast addresses", %{ncm: ncm} do
      path = "/api/usb/network"
      body = ~s({"host_address":"02:12:34:56:78:9A","device_address":null})
      assert request(:post, path, body, [{"content-type", "application/json"}]).status == 403
      assert request(:post, path, ~s({"mac":"02:12:34:56:78:9a"}), @page).status == 400
      assert request(:post, path, ~s({"host_address":5}), @page).status == 400

      conn = request(:post, path, ~s({"host_address":"01:00:5e:00:00:fb"}), @page)
      assert conn.status == 400

      assert Jason.decode!(conn.resp_body) == %{
               "error" => "multicast_address",
               "field" => "host_address"
             }

      conn = request(:post, path, ~s({"host_address":"9e:9f:51:11:f7:b2"}), @page)
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body) == %{"error" => "same_addresses"}

      assert request(:post, path, body, @page).status == 202
      assert File.read!(Path.join(ncm, "host_addr")) =~ "7a:78:1f:1f:1d:dd"

      assert_receive {KV, %{"usbnet_hostaddr" => "02:12:34:56:78:9a", "usbnet_devaddr" => ""}},
                     2_000

      assert File.read!(Path.join(ncm, "host_addr")) == "02:12:34:56:78:9a"
    end
  end

  describe "the auxiliary port's lines" do
    defmodule GPIO do
      # Circuits.GPIO with both lines high.
      def open(name, _direction, _opts), do: {:ok, name}
      def read(_name), do: 1
      def write(_name, _value), do: :ok
      def set_interrupts(_name, _trigger, _opts), do: :ok
      def close(_name), do: :ok
    end

    defmodule ExpansionKV do
      # Nerves.Runtime.KV with nothing kept.
      def get(_variable), do: nil
      def put(_variables), do: :ok
    end

    # The driver's attributes and a PWM chip, with their own NanoKVMGo.Expansion.
    setup %{tmp_dir: tmp_dir} do
      device = Path.join(tmp_dir, "expansion")
      chip = Path.join(tmp_dir, "pwmchip0")
      File.mkdir_p!(device)
      for channel <- ["pwm0", "pwm1"], do: File.mkdir_p!(Path.join(chip, channel))
      File.write!(Path.join(device, "mode"), "off\n")
      File.write!(Path.join(device, "modes"), "off uart gpio pwm pwm-gpio gpio-pwm i2c\n")

      start_supervised!(
        {NanoKVMGo.Expansion,
         name: __MODULE__.Expansion, device: device, pwm_chip: chip, kv: ExpansionKV, gpio: GPIO}
      )

      Application.put_env(:kuroneko, :expansion_server, __MODULE__.Expansion)
      on_exit(fn -> Application.delete_env(:kuroneko, :expansion_server) end)
      %{device: device, chip: chip}
    end

    test "modes, PWM and GPIO only from the page, only as the mode allows", %{
      device: device,
      chip: chip
    } do
      json_only = [{"content-type", "application/json"}]
      assert request(:post, "/api/expansion/mode", ~s({"mode":"uart"}), json_only).status == 403

      for body <- [~s({"mode":"sideways"}), ~s({"mode":1}), ~s({})],
          do: assert(request(:post, "/api/expansion/mode", body, @page).status == 400, body)

      assert request(:post, "/api/expansion/mode", ~s({"mode":"pwm_gpio"}), @page).status == 200
      assert File.read!(Path.join(device, "mode")) == "pwm-gpio"

      for body <- [
            ~s({"line":2,"period":20000000,"duty_cycle":0}),
            ~s({"line":0,"period":999,"duty_cycle":0}),
            ~s({"line":0,"period":20000000,"duty_cycle":20000001}),
            ~s({"line":0,"period":"fast","duty_cycle":0})
          ],
          do: assert(request(:post, "/api/expansion/pwm", body, @page).status == 400, body)

      body = ~s({"line":0,"period":20000000,"duty_cycle":2050000})
      assert request(:post, "/api/expansion/pwm", body, @page).status == 200
      assert File.read!(Path.join([chip, "pwm0", "duty_cycle"])) == "2050000"

      conn = request(:post, "/api/expansion/pwm", ~s({"line":1,"stop":true}), @page)
      assert conn.status == 200

      conn =
        request(:post, "/api/expansion/pwm", ~s({"line":1,"period":40000,"duty_cycle":0}), @page)

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body) == %{"error" => "not_pwm", "line" => 1}

      conn = request(:post, "/api/expansion/gpio", ~s({"line":1,"value":null}), @page)
      assert {conn.status, Jason.decode!(conn.resp_body)} == {200, %{"value" => 1}}
      assert request(:post, "/api/expansion/gpio", ~s({"line":1,"value":2}), @page).status == 400
      assert request(:post, "/api/expansion/gpio", ~s({"line":0,"value":1}), @page).status == 409

      assert request(:post, "/api/expansion/pwm", ~s({"line":0,"stop":true}), @page).status == 200
      assert File.read!(Path.join([chip, "pwm0", "enable"])) == "0"
    end

    test "tells when the lines are not there" do
      Application.put_env(:kuroneko, :expansion_server, __MODULE__.None)
      assert request(:post, "/api/expansion/mode", ~s({"mode":"uart"}), @page).status == 503
    end
  end

  describe "Wi-Fi" do
    defmodule FakeWiFi do
      def overview(opts) do
        if opts[:scan], do: tell(:scanned)

        %{
          present: true,
          network: "home",
          country: "JP",
          connection: :internet,
          address: "192.0.2.10",
          link: nil,
          networks: [%{ssid: "home", signal_percent: 80, band: "5 GHz", security: :personal}]
        }
      end

      def scan, do: tell(:scanned)
      defdelegate country_code(code), to: Kuroneko.WiFi
      def set_country(code), do: tell({:country, code})
      def config("", _passphrase, _opts), do: {:error, :ssid_too_short}
      def config(_ssid, "short", _opts), do: {:error, :password_too_short}

      def config(ssid, passphrase, opts),
        do: {:ok, %{ssid: ssid, passphrase: passphrase, hidden: opts[:hidden]}}

      def apply_config(config), do: tell({:applied, config})
      def forget, do: tell(:forgot)

      defp tell(message) do
        send(Kuroneko.WebTest, message)
        :ok
      end
    end

    setup do
      Process.register(self(), Kuroneko.WebTest)
      Application.put_env(:kuroneko, :wifi, FakeWiFi)
      on_exit(fn -> Application.delete_env(:kuroneko, :wifi) end)
    end

    test "the state and the networks in reach, scanning again when the page asks" do
      assert %{
               "network" => "home",
               "country" => "JP",
               "networks" => [%{"ssid" => "home", "security" => "personal"}]
             } = Jason.decode!(request(:get, "/api/wifi").resp_body)

      refute_receive :scanned, 100
      assert request(:get, "/api/wifi?scan=1").status == 200
      assert_receive :scanned
    end

    test "follows a country's rules after the reply, from the page only" do
      evil = [{"origin", "http://evil.example"}, {"content-type", "application/json"}]
      assert request(:post, "/api/wifi/country", ~s({"country":"jp"}), evil).status == 403

      conn = request(:post, "/api/wifi/country", ~s({"country":"jp"}), @page)
      assert {conn.status, Jason.decode!(conn.resp_body)} == {202, %{"country" => "JP"}}
      assert_receive {:country, "JP"}, 2_000

      conn = request(:post, "/api/wifi/country", ~s({"country":"Japan"}), @page)

      assert {conn.status, Jason.decode!(conn.resp_body)} ==
               {400, %{"error" => "not a country code"}}

      assert request(:post, "/api/wifi/country", ~s({"code":"JP"}), @page).status == 400
      refute_receive {:country, _code}, 700
    end

    test "joins a network after the reply, from the page only" do
      evil = [{"origin", "http://evil.example"}, {"content-type", "application/json"}]

      assert request(:post, "/api/wifi", ~s({"ssid":"home","passphrase":"long enough"}), evil).status ==
               403

      assert request(:post, "/api/wifi", ~s({"ssid":"home","passphrase":"long enough"}), @page).status ==
               202

      assert_receive {:applied, %{ssid: "home", passphrase: "long enough", hidden: false}}, 2_000

      assert request(
               :post,
               "/api/wifi",
               ~s({"ssid":"lab","passphrase":null,"hidden":true}),
               @page
             ).status == 202

      assert_receive {:applied, %{ssid: "lab", passphrase: nil, hidden: true}}, 2_000
    end

    test "says what is wrong with a network or a passphrase" do
      for {body, error} <- [
            {~s({"ssid":"","passphrase":"long enough"}), "the network needs a name"},
            {~s({"ssid":"home","passphrase":"short"}),
             "the passphrase needs at least 8 characters"}
          ] do
        conn = request(:post, "/api/wifi", body, @page)
        assert {conn.status, Jason.decode!(conn.resp_body)} == {400, %{"error" => error}}
      end

      for body <- [~s({"ssid":"home","passphrase":8}), ~s({"passphrase":"long enough"}), ~s([1])] do
        assert request(:post, "/api/wifi", body, @page).status == 400, body
      end

      refute_receive {:applied, _config}, 700
    end

    test "scans and forgets" do
      assert request(:post, "/api/wifi/scan", "{}", @page).status == 202
      assert_receive :scanned
      assert request(:post, "/api/wifi/forget", "{}", @page).status == 202
      assert_receive :forgot, 2_000
    end
  end

  describe "USB network addresses" do
    defmodule FakeUSBNetwork do
      def check(nil), do: :ok
      def check("10.55.0.1/24"), do: :ok
      def check(_address), do: {:error, :invalid_address}

      def set(address) do
        send(Kuroneko.WebTest, {:set, address})
        :ok
      end
    end

    setup do
      Process.register(self(), Kuroneko.WebTest)
      Application.put_env(:kuroneko, :usb_network, FakeUSBNetwork)
      on_exit(fn -> Application.delete_env(:kuroneko, :usb_network) end)
    end

    test "moves after the reply, for the page only, and says why not" do
      evil = [{"origin", "http://evil.example"}, {"content-type", "application/json"}]
      body = ~s({"address":"10.55.0.1/24"})
      assert request(:post, "/api/usb/addresses", body, evil).status == 403

      assert request(:post, "/api/usb/addresses", body, @page).status == 202
      assert_receive {:set, "10.55.0.1/24"}, 2_000
      assert request(:post, "/api/usb/addresses", ~s({"address":null}), @page).status == 202
      assert_receive {:set, nil}, 2_000

      conn = request(:post, "/api/usb/addresses", ~s({"address":"10.55"}), @page)

      assert {conn.status, Jason.decode!(conn.resp_body)} ==
               {400, %{"error" => "invalid_address"}}

      assert request(:post, "/api/usb/addresses", ~s({"address":5}), @page).status == 400
    end
  end

  describe "virtual disk" do
    defmodule FakeDisk do
      def state do
        %{
          items: [%{name: "debian.iso", kind: :image, size: 3}],
          drives: [%{drive: 0, medium: nil}, %{drive: 1, medium: nil}],
          busy: nil
        }
      end

      def insert("busy.iso", _opts), do: {:error, :busy}
      def insert("Odd", _opts), do: {:error, {:bad_name, "Odd/a:b.txt"}}
      def insert(name, opts), do: tell({:insert, name, opts})
      def eject(drive), do: tell({:ejected, drive})
      def delete(name), do: tell({:deleted, name})

      def upload_paths(name, opts) do
        dir = Application.fetch_env!(:kuroneko, :fake_disk_dir)

        with {:ok, path} <- Kuroneko.VirtualDisk.library_path(name) do
          final = Path.join(dir, path)

          if File.exists?(final) and not opts[:replace],
            do: {:error, :exists},
            else: {:ok, final, Path.join(dir, "upload")}
        end
      end

      defdelegate finish_upload(temporary, final), to: Kuroneko.VirtualDisk

      defp tell(message) do
        send(Kuroneko.WebTest, message)
        :ok
      end
    end

    setup %{tmp_dir: tmp_dir} do
      Process.register(self(), Kuroneko.WebTest)
      Application.put_env(:kuroneko, :virtual_disk, FakeDisk)
      Application.put_env(:kuroneko, :fake_disk_dir, tmp_dir)

      on_exit(fn ->
        Application.delete_env(:kuroneko, :virtual_disk)
        Application.delete_env(:kuroneko, :fake_disk_dir)
      end)
    end

    test "the library and the drives" do
      assert %{
               "items" => [%{"name" => "debian.iso", "kind" => "image"}],
               "drives" => [%{"drive" => 0, "medium" => nil}, %{"drive" => 1, "medium" => nil}]
             } = Jason.decode!(request(:get, "/api/disk").resp_body)
    end

    test "inserts, ejects and deletes for the page only, and says why not" do
      evil = [{"origin", "http://evil.example"}, {"content-type", "application/json"}]
      body = ~s({"name":"debian.iso","media":"dvd"})
      assert request(:post, "/api/disk/insert", body, evil).status == 403

      assert request(:post, "/api/disk/insert", body, @page).status == 202
      assert_receive {:insert, "debian.iso", [media: :dvd]}

      body = ~s({"name":"debian.iso","media":"drive","read_only":false,"remember":false})
      assert request(:post, "/api/disk/insert", body, @page).status == 202
      assert_receive {:insert, "debian.iso", [media: :drive, read_only: false, remember: false]}

      conn = request(:post, "/api/disk/insert", ~s({"name":"busy.iso"}), @page)
      assert {conn.status, Jason.decode!(conn.resp_body)} == {409, %{"error" => "busy"}}

      folder = ~s({"name":"Photos","read_only":false,"filesystem":"fat32"})
      assert request(:post, "/api/disk/insert", folder, @page).status == 202
      assert_receive {:insert, "Photos", [filesystem: :fat32, read_only: false]}
      odd = ~s({"name":"Photos","filesystem":"ntfs"})
      assert request(:post, "/api/disk/insert", odd, @page).status == 202
      assert_receive {:insert, "Photos", []}

      conn = request(:post, "/api/disk/insert", ~s({"name":"Odd"}), @page)

      assert {conn.status, Jason.decode!(conn.resp_body)} ==
               {400, %{"error" => "bad_name", "name" => "Odd/a:b.txt"}}

      assert request(:post, "/api/disk/insert", ~s({"name":"debian.iso","drive":1}), @page).status ==
               202

      assert_receive {:insert, "debian.iso", [drive: 1]}

      assert request(:post, "/api/disk/eject", "{}", @page).status == 202
      assert_receive {:ejected, 0}
      assert request(:post, "/api/disk/eject", ~s({"drive":1}), @page).status == 202
      assert_receive {:ejected, 1}
      assert request(:post, "/api/disk/delete", ~s({"name":"debian.iso"}), @page).status == 200
      assert_receive {:deleted, "debian.iso"}
      assert request(:post, "/api/disk/delete", ~s({"file":"debian.iso"}), @page).status == 400
    end

    test "an upload goes into the library as it comes", %{tmp_dir: tmp_dir} do
      file = [{"origin", "http://www.example.com"}, {"content-type", "application/octet-stream"}]
      body = :crypto.strong_rand_bytes(3_000_000)

      assert request(:put, "/api/disk/files?name=os.iso", body, file).status == 201
      assert File.read!(Path.join(tmp_dir, "os.iso")) == body
      refute File.exists?(Path.join(tmp_dir, "upload"))

      conn = request(:put, "/api/disk/files?name=os.iso", "again", file)
      assert {conn.status, Jason.decode!(conn.resp_body)} == {409, %{"error" => "exists"}}
      assert request(:put, "/api/disk/files?name=os.iso&replace=1", "again", file).status == 201
      assert File.read!(Path.join(tmp_dir, "os.iso")) == "again"

      assert request(:put, "/api/disk/files?name=Photos%2Fa.jpg", "jpeg", file).status == 201
      assert File.read!(Path.join(tmp_dir, "Photos/a.jpg")) == "jpeg"

      assert request(:put, "/api/disk/files?name=..%2Fx", "x", file).status == 400

      assert request(:put, "/api/disk/files?name=x", "x", [{"origin", "http://evil.example"}]).status ==
               403
    end
  end

  describe "SSH keys" do
    defmodule FakeSSH do
      def keys,
        do: [
          %{key: "ssh-ed25519 AAAA test", type: "ssh-ed25519", comment: "test", built_in: false}
        ]

      def add_keys("not a key"), do: {:error, :invalid_key}
      def add_keys(_text), do: :ok
      def remove_key("built in"), do: {:error, :built_in}
      def remove_key(_line), do: :ok
    end

    setup do
      Application.put_env(:kuroneko, :ssh, FakeSSH)
      on_exit(fn -> Application.delete_env(:kuroneko, :ssh) end)
    end

    test "lists, adds and removes keys from the page" do
      assert %{"keys" => [%{"comment" => "test"}]} =
               Jason.decode!(request(:get, "/api/ssh/keys").resp_body)

      json_only = [{"content-type", "application/json"}]

      assert request(:post, "/api/ssh/keys", ~s({"key":"ssh-ed25519 AAAA"}), json_only).status ==
               403

      assert request(:post, "/api/ssh/keys", ~s({"key":"ssh-ed25519 AAAA"}), @page).status == 200
      assert request(:post, "/api/ssh/keys", ~s({"key":"not a key"}), @page).status == 400
      assert request(:post, "/api/ssh/keys", ~s({"key":1}), @page).status == 400

      assert request(:post, "/api/ssh/keys/remove", ~s({"key":"ssh-ed25519 AAAA"}), @page).status ==
               200

      conn = request(:post, "/api/ssh/keys/remove", ~s({"key":"built in"}), @page)

      assert {conn.status, Jason.decode!(conn.resp_body)} ==
               {400, %{"error" => "built into the firmware"}}
    end
  end
end
