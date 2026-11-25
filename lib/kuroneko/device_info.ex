defmodule Kuroneko.DeviceInfo do
  @moduledoc """
  What the device page shows, as JSON takes it. The hardware comes from
  `NanoKVMGo.Hardware` and `NanoKVMGo.Metrics`, the firmware from
  `Nerves.Runtime`, the network from VintageNet; this module only puts them
  together. A process that is not running leaves its part `nil`.

    * `overview/0` - everything, when the page opens: the board and its
      parts, the storage, the firmware and software, the status and the
      metrics with their history
    * `status/0` - what changes, each second: the video input, the USB
      connection and its network's addresses, the LCD, the expansion lines,
      the network, the BEAM and the firmware's trial
  """

  alias Kuroneko.Gadget
  alias NanoKVMGo.{Backlight, Expansion, Hardware, Metrics, Video}
  alias Kuroneko.Network

  @doc "Everything the page shows."
  @spec overview() :: map()
  def overview do
    %{
      hostname: hostname(),
      hardware: Hardware.info(),
      components: Hardware.components(),
      storage: Hardware.storage(),
      firmware: firmware(),
      software: software(),
      status: status(),
      metrics: %{current: safely(&Metrics.current/0), history: safely(&Metrics.history/0)}
    }
  end

  @doc "What changes while the page is open."
  @spec status() :: map()
  def status do
    %{
      video: %{input: safely(&Video.input/0), capture: Video.capture_stats()},
      usb: usb(),
      screen: screen(),
      expansion: expansion(),
      network: network(),
      beam: %{
        memory: :erlang.memory(:total),
        processes: :erlang.system_info(:process_count),
        schedulers: :erlang.system_info(:schedulers_online)
      },
      trial: trial()
    }
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  # Both firmware slots, the running one marked.
  defp firmware do
    kv = Nerves.Runtime.KV.get_all()
    active = kv["nerves_fw_active"]

    slots =
      for slot <- ["a", "b"], kv["#{slot}.nerves_fw_version"] || kv["#{slot}.nerves_fw_uuid"] do
        field = fn key -> kv["#{slot}.nerves_fw_#{key}"] end

        %{
          slot: slot,
          active: slot == active,
          version: field.("version"),
          uuid: field.("uuid"),
          product: field.("product"),
          platform: field.("platform"),
          architecture: field.("architecture"),
          author: field.("author"),
          vcs: field.("vcs_identifier")
        }
      end

    %{active: active, slots: slots}
  end

  # The firmware's trial, and the memory sizes' (NanoKVMGo.CMA.trial/1) when
  # this boot runs them: validating the firmware keeps both.
  defp trial do
    memory =
      case safely(&NanoKVMGo.CMA.trial/0) do
        %{state: :running, sizes: sizes} -> sizes
        _ -> nil
      end

    %{
      validated: Nerves.Runtime.firmware_valid?(),
      memory: memory,
      revert_in: Kuroneko.TrialGuard.remaining()
    }
  end

  defp software do
    %{
      app: vsn(:kuroneko),
      nano_kvm_go: vsn(:nano_kvm_go),
      kuroneko_gadget: vsn(:kuroneko_gadget),
      elixir: System.version(),
      otp: System.otp_release(),
      erts: to_string(:erlang.system_info(:version)),
      architecture: to_string(:erlang.system_info(:system_architecture))
    }
  end

  defp vsn(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp usb do
    functions = safely(&Gadget.functions/0)

    %{
      connection: ok_or_nil(Gadget.connection()),
      functions: functions,
      media: if(functions && :storage in functions, do: Kuroneko.VirtualDisk.media(), else: []),
      network: ok_or_nil(safely(&Gadget.network/0)),
      endpoints: safely(&Gadget.endpoints_in_use/0),
      addresses: Kuroneko.USBNetwork.current()
    }
  end

  # Each line with the edges Kuroneko.ExpansionWatch counted.
  defp expansion do
    with {:ok, info} <- safely(&Expansion.info/0) do
      edges = safely(&Kuroneko.ExpansionWatch.edges/0) || %{}
      %{info | lines: Enum.map(info.lines, &Map.put(&1, :edges, edges[&1.line]))}
    else
      _ -> nil
    end
  end

  defp screen do
    case Kuroneko.Screen.settings() do
      {:ok, settings} -> Map.put(settings, :backlight, ok_or_nil(safely(&Backlight.info/0)))
      {:error, _reason} -> nil
    end
  end

  defp network do
    Map.new(Network.interfaces(), fn ifname ->
      get = &Network.get(ifname, &1)

      {ifname,
       %{
         kind: kind(get.(["type"])),
         state: get.(["state"]),
         connection: get.(["connection"]),
         mac: get.(["mac_address"]),
         addresses: Network.addresses(ifname),
         wifi: if(get.(["type"]) == VintageNetWiFi, do: Network.wifi(ifname))
       }}
    end)
  end

  defp kind(VintageNetWiFi), do: :wifi
  defp kind(VintageNetDirect), do: :usb
  defp kind(VintageNetEthernet), do: :ethernet
  defp kind(_type), do: nil

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(_other), do: nil

  # A part not running, or not answering, is unknown.
  defp safely(fun) do
    fun.()
  catch
    :exit, {reason, _call} when reason in [:noproc, :timeout] -> nil
  end
end
