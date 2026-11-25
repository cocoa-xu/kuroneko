defmodule Kuroneko.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    migrate()

    children =
      [
        Kuroneko.LoginLimit,
        Kuroneko.SetupCode,
        Kuroneko.WiFi.Scanner,
        Kuroneko.VideoSettings
      ] ++ target_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kuroneko.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      init_complete()
      {:ok, pid}
    end
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp migrate(), do: :ok
    defp init_complete(), do: :ok

    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
        #
        # Starts a worker by calling: Host.Worker.start_link(arg)
        # {Host.Worker, arg},
      ]
    end
  else
    require Logger

    # vm.args sets HEART_INIT_TIMEOUT: without this handshake heart stops
    # petting the watchdog 600 s after boot. The StartupGuard, which would do
    # it, is off so that firmware is validated by hand (TrialGuard).
    defp init_complete(), do: Nerves.Runtime.Heart.init_complete()

    # Before anything reads its settings.
    defp migrate() do
      with {:error, reason} <- Kuroneko.Migration.run() do
        Logger.error("kuroneko: /data/nanokvm_hello not moved: #{inspect(reason)}")
      end
    end

    # The USB devices follow the saved settings: the keyboard and mouse and
    # the virtual disk by default, the sound card when turned on.
    defp target_children() do
      usb_functions = Kuroneko.USBSettings.functions(Kuroneko.USBSettings.saved())
      # The MJPEG stream, served apart, goes to pages with a session: they get
      # this token, made anew each boot.
      mjpeg_token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      Application.put_env(:kuroneko, :mjpeg_token, mjpeg_token)

      [
        {Task.Supervisor, name: Kuroneko.TaskSupervisor},
        # The Wi-Fi and SSH keys the card was burned with.
        {Task, &Kuroneko.Provisioning.run/0},
        Kuroneko.TrialGuard,
        {Kuroneko.Gadget,
         NanoKVMGo.USB.gadget_options() ++ [functions: usb_functions, manage_networks: true]},
        Supervisor.child_spec({Task, &Kuroneko.USBNetwork.configure_more/0}, id: :usb_networks),
        Kuroneko.VirtualDisk,
        {NanoKVMGo.Video,
         mjpeg_port: 8088,
         mjpeg_token: mjpeg_token,
         jpeg_quality: 60,
         encoding: {Kuroneko.VideoSettings, :encoding, []}},
        NanoKVMGo.Audio,
        {NanoKVMGo.Audio, source: :usb, name: Kuroneko.Speaker},
        NanoKVMGo.Microphone,
        Kuroneko.Gadget.Input,
        Kuroneko.Jiggler,
        NanoKVMGo.Display,
        NanoKVMGo.Metrics,
        NanoKVMGo.Expansion,
        Kuroneko.ExpansionWatch,
        NanoKVMGo.Touch,
        NanoKVMGo.Button,
        Kuroneko.Screen,
        {Bandit, plug: Kuroneko.Web, port: 80}
      ] ++ https()
    end

    # Without a certificate the page still works, but not the microphone.
    # With HTTPS, the page on HTTP sends browsers there.
    defp https() do
      options = Kuroneko.TLS.options()
      Application.put_env(:kuroneko, :https_redirect, true)
      [{Bandit, [plug: Kuroneko.Web, scheme: :https, port: 443] ++ options}]
    rescue
      e ->
        Logger.error("kuroneko: no HTTPS: #{Exception.message(e)}")
        []
    end
  end
end
