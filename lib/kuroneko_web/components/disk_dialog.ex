defmodule KuronekoWeb.DiskDialog do
  @moduledoc false
  # The virtual disk's dialog: the library, what is in the drives, uploads.
  # A page keeps it rendered, open or not, so that an upload goes on while it
  # is closed. The page gives `open` and `drive`, the drive to insert into,
  # and hears `{KuronekoWeb.DiskDialog, :closed}` when it closes.
  #
  # Uploads go from the browser straight to PUT /api/disk/files (the .Upload
  # hook): gigabytes go to the card as they come, not through the socket.

  use KuronekoWeb, :live_component

  alias KuronekoWeb.Format

  @refresh_ms 1_500

  @errors %{
    busy: "The virtual disk is busy: wait until it is done.",
    eject_first: "Eject the writable folder first: its changes go back to it then.",
    in_use: "That is in a drive or in use.",
    exists: "There is one of that name already.",
    invalid_name: "The library does not take that name.",
    enoent: "That is not in the library any more.",
    file_too_large: "A file is larger than 4 GiB, more than FAT32 holds: choose exFAT.",
    no_exfat: "This NanoKVM's system has no exFAT: update it, or choose FAT32.",
    disc_unsupported: "This NanoKVM's system has CD drives only: update it, or choose CD-ROM.",
    no_room: "Not enough free space on the NanoKVM.",
    no_storage: "The virtual disk is off: turn it on under USB on the device page.",
    no_drive: "There is no such drive.",
    cd_only: "A CUE sheet is a CD: insert it as Auto or CD-ROM.",
    tracks_unsupported: "This NanoKVM's system has no CDs of tracks: update it.",
    no_maker: "That maker is not on this NanoKVM any more.",
    not_offered: "That maker does not offer this mode for it.",
    broken: "the upload broke off."
  }
  @error_names Map.new(@errors, fn {reason, text} -> {Atom.to_string(reason), text} end)
  @filesystems %{exfat: "exFAT", fat32: "FAT32"}
  @drives %{cd: "CD-ROM", dvd: "DVD-ROM", bd: "BD-ROM"}
  @discs %{cd: "CD", dvd: "DVD", bd: "Blu-ray"}
  @boots %{bios: "BIOS", uefi: "UEFI", other: "other firmware"}
  @media %{"auto" => :auto, "cd" => :cd, "dvd" => :dvd, "bd" => :bd}

  @doc "Why the virtual disk refused, as the pages say it."
  def error_text({:bad_name, name}),
    do: "“#{name}” has a character drives do not take (\" * : < > ? \\ |): rename it first."

  def error_text({:cue, detail}), do: "The CUE sheet cannot go in: #{detail}."
  def error_text(reason) when is_atom(reason), do: Map.get(@errors, reason, inspect(reason))
  def error_text(reason) when is_binary(reason), do: Map.get(@error_names, reason, reason)
  def error_text(reason), do: inspect(reason)

  @doc "How a drive holds its medium."
  def describe(medium) do
    access = if medium.read_only, do: "read-only", else: "writable"
    kept = if medium[:remember], do: ", in again after a restart", else: ""

    cond do
      medium[:label] ->
        "#{medium.label}, #{access}#{kept}"

      medium.kind == :folder ->
        "folder as #{@filesystems[medium[:filesystem]] || "a drive"}, #{access}#{kept}"

      true ->
        drive = if medium[:cdrom], do: @drives[medium[:disc]] || "CD-ROM", else: "USB drive"
        tracks = if medium[:tracks], do: " of #{medium.tracks} tracks", else: ""
        "#{drive}#{tracks}, #{access}#{kept}"
    end
  end

  @doc "A drive by number, and by its storage device when there are several."
  def drive_name(%{drives: [_]}, _drive), do: "The drive"

  def drive_name(%{drives: drives}, drive) do
    if drives |> Enum.map(& &1.storage) |> Enum.uniq() |> length() > 1,
      do: "Drive #{drive.drive + 1} (#{drive.storage})",
      else: "Drive #{drive.drive + 1}"
  end

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open: false,
       drive: nil,
       disk: nil,
       target: 0,
       remember: true,
       choices: %{},
       error: nil,
       ticking: false
     )}
  end

  @impl true
  def update(%{refresh: true}, socket) do
    socket = assign(socket, ticking: false)
    {:ok, if(socket.assigns.open, do: socket |> refresh() |> tick(), else: socket)}
  end

  def update(assigns, socket) do
    opening = assigns[:open] == true and not socket.assigns.open
    socket = assign(socket, Map.take(assigns, [:id, :open, :drive]))

    {:ok,
     if(opening,
       do: socket |> assign(error: nil, target: assigns[:drive]) |> refresh() |> tick(),
       else: socket
     )}
  end

  # While open, the dialog reads the library each moment: SFTP changes it too.
  defp tick(%{assigns: %{ticking: true}} = socket), do: socket

  defp tick(socket) do
    send_update_after(self(), socket.assigns.myself, %{refresh: true}, @refresh_ms)
    assign(socket, ticking: true)
  end

  defp refresh(socket) do
    disk = disk().state()
    assign(socket, disk: disk, target: target(disk.drives, socket.assigns.target))
  catch
    :exit, _not_running -> assign(socket, disk: nil, error: "The virtual disk is not running.")
  end

  # The drive asked for, else the first empty one, else the first.
  defp target(drives, wanted) do
    if Enum.any?(drives, &(&1.drive == wanted)),
      do: wanted,
      else: Enum.find_value(drives, 0, &(&1.medium == nil && &1.drive))
  end

  @impl true
  def handle_event("close", _params, socket) do
    if socket.assigns.open, do: send(self(), {__MODULE__, :closed})
    {:noreply, assign(socket, open: false)}
  end

  def handle_event("target", %{"drive" => drive}, socket),
    do: {:noreply, assign(socket, target: String.to_integer(drive))}

  def handle_event("remember", _params, socket),
    do: {:noreply, assign(socket, remember: not socket.assigns.remember)}

  def handle_event("mode", %{"name" => name, "mode" => mode}, socket),
    do: {:noreply, assign(socket, choices: Map.put(socket.assigns.choices, name, mode))}

  def handle_event("insert", %{"name" => name}, socket) do
    case Enum.find(socket.assigns.disk.items, &(&1.name == name)) do
      nil ->
        {:noreply, socket |> assign(error: error_text(:enoent)) |> refresh()}

      item ->
        mode = Map.get(socket.assigns.choices, name, item |> modes() |> hd() |> elem(0))
        act(socket, fn -> disk().insert(name, insert_options(item, mode, socket.assigns)) end)
    end
  end

  def handle_event("eject", %{"drive" => drive}, socket),
    do: act(socket, fn -> disk().eject(String.to_integer(drive)) end)

  def handle_event("delete", %{"name" => name}, socket),
    do: act(socket, fn -> disk().delete(name) end)

  def handle_event("uploaded", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("upload_failed", %{"name" => name, "error" => error}, socket) do
    {:noreply, socket |> assign(error: "Upload of “#{name}”: #{error_text(error)}") |> refresh()}
  end

  defp act(socket, call) do
    error =
      case call.() do
        :ok -> nil
        {:error, reason} -> error_text(reason)
      end

    {:noreply, socket |> assign(error: error) |> refresh()}
  end

  defp insert_options(item, mode, assigns) do
    base = [drive: assigns.target, remember: assigns.remember]
    offer = Enum.find(item[:makers] || [], &(offer_value(&1) == mode))

    cond do
      offer ->
        base ++ [maker: offer.maker, mode: offer.mode]

      item.kind == :folder ->
        [filesystem, access] = String.split(mode, "-")

        base ++
          [
            filesystem: if(filesystem == "fat32", do: :fat32, else: :exfat),
            read_only: access == "ro"
          ]

      String.starts_with?(mode, "drive-") ->
        base ++ [media: :drive, read_only: mode == "drive-ro"]

      true ->
        base ++ [media: Map.get(@media, mode, :auto)]
    end
  end

  defp offer_value(offer), do: "maker:#{offer.maker}:#{offer.mode}"

  # How an item can go in, the first being the default; then what makers offer.
  defp modes(item) do
    made = Enum.map(item[:makers] || [], &{offer_value(&1), &1.label})
    format = item[:format] || %{}

    cond do
      item.kind == :folder ->
        [
          {"exfat-ro", "exFAT, read-only"},
          {"exfat-rw", "exFAT, writable"},
          {"fat32-ro", "FAT32, read-only"},
          {"fat32-rw", "FAT32, writable"}
        ] ++ made

      format[:cue] ->
        [{"auto", "Auto: CD-ROM"} | made]

      true ->
        auto =
          if format[:disc], do: "Auto: #{@drives[format.disc]}", else: "Auto: USB drive, writable"

        [
          {"auto", auto},
          {"cd", "CD-ROM"},
          {"dvd", "DVD-ROM"},
          {"bd", "BD-ROM"},
          {"drive-ro", "USB drive, read-only"},
          {"drive-rw", "USB drive, writable"}
        ] ++ made
    end
  end

  # What an image holds, from its own structures.
  defp format_text(%{cue: %{error: error}}) when is_binary(error),
    do: "CUE sheet the drive cannot take: #{error}"

  defp format_text(%{cue: cue}) when is_map(cue) do
    data = cue[:data] || 0
    audio = cue[:audio] || 0

    tracks =
      [data > 0 && "#{data} data", audio > 0 && "#{audio} audio"]
      |> Enum.filter(& &1)
      |> Enum.join(" and ")

    "CUE sheet: a CD of #{tracks} track#{if data + audio > 1, do: "s"}"
  end

  defp format_text(format) when is_map(format) do
    systems =
      Enum.filter(
        [
          format[:iso9660] && "ISO 9660",
          format[:joliet] && "Joliet",
          format[:udf] && "UDF #{format.udf}"
        ],
        & &1
      )

    disc =
      format[:disc] &&
        "#{@discs[format.disc]} format" <>
          if(systems != [], do: " (#{Enum.join(systems, ", ")})", else: "") <>
          if(format[:layers] == 2, do: ", two layers", else: "")

    boots =
      (format[:boot] || []) != [] &&
        "boots #{Enum.map_join(format.boot, " and ", &(@boots[&1] || to_string(&1)))}"

    table =
      cond do
        format[:partitions] ->
          "#{format.partitions |> to_string() |> String.upcase()} partition table" <>
            if(format[:disc], do: ": boots as a USB drive too", else: "")

        format[:disc] ->
          nil

        true ->
          "no disc format or partition table found"
      end

    [disc, boots, table] |> Enum.filter(& &1) |> Enum.join("; ")
  end

  defp format_text(_format), do: nil

  defp item_detail(item) do
    kind = if item.kind == :folder, do: "Folder", else: format_text(item[:format])
    Enum.join(Enum.filter([Format.bytes(item.size), kind], & &1), ", ")
  end

  defp busy_text(%{busy: busy, drives: drives}) do
    percent =
      if busy[:total] && busy.total > 0, do: " #{div(100 * busy.done, busy.total)}%", else: ""

    into = if length(drives) > 1, do: " for drive #{busy.drive + 1}", else: ""

    if busy.action == :making,
      do: "Making a drive from #{busy.name}#{into}:#{percent}",
      else: "Copying the changes back to #{busy.name}:#{percent}"
  end

  # Each library item with what its row shows: the drive it is in, how it
  # can go in and the way chosen.
  defp rows(nil, _choices), do: []

  defp rows(disk, choices) do
    for {item, index} <- Enum.with_index(disk.items) do
      holder = Enum.find(disk.drives, &(&1.medium && &1.medium.name == item.name))
      modes = modes(item)

      %{
        id: "item-#{index}",
        item: item,
        detail: item_detail(item),
        holder:
          holder &&
            if(length(disk.drives) > 1, do: "In drive #{holder.drive + 1}", else: "In the drive"),
        modes: modes,
        choice: Map.get(choices, item.name, modes |> hd() |> elem(0)),
        locked: holder != nil or (disk.busy != nil and disk.busy.name == item.name),
        hint:
          if(item.kind == :folder,
            do:
              "exFAT holds files of any size; FAT32 is for BIOS updates, UEFI and older systems.",
            else: "Auto follows what the image holds; the others force it."
          )
      }
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, rows: rows(assigns.disk, assigns.choices))

    ~H"""
    <div id={@id}>
      <.modal
        id={"#{@id}-sheet"}
        show={@open}
        title="Virtual disk"
        cancel="close"
        target={@myself}
        class="max-w-[46rem]"
      >
        <%= if @open && @disk do %>
          <div class="space-y-1.5">
            <div
              :for={d <- @disk.drives}
              class="flex items-center gap-3 rounded-field bg-base-200/70 px-3 py-2"
            >
              <.icon
                name={if d.medium, do: "hero-circle-stack-solid", else: "hero-circle-stack"}
                class={[
                  "size-5 shrink-0",
                  if(d.medium, do: "text-primary", else: "text-base-content/35")
                ]}
              />
              <div class="min-w-0 flex-1">
                <div class="truncate text-sm font-medium">
                  {drive_name(@disk, d)}{if d.medium, do: ": #{d.medium.name}"}
                </div>
                <div class="truncate text-xs text-base-content/55">
                  {if d.medium, do: describe(d.medium), else: "Empty"}
                </div>
              </div>
              <.button
                :if={d.medium}
                size={:sm}
                phx-click="eject"
                phx-value-drive={d.drive}
                phx-target={@myself}
                disabled={@disk.busy != nil}
              >
                Eject
              </.button>
            </div>
            <p :if={@disk.drives == []} class="text-sm text-base-content/60">
              There is no drive: turn the virtual disk on under USB on the device page.
            </p>
          </div>

          <div :if={@disk.busy} class="mt-3 flex items-center gap-3 text-xs text-base-content/70">
            <progress
              class="progress progress-primary h-1.5 w-32"
              max={@disk.busy[:total] || 100}
              value={@disk.busy[:done] || 0}
            />
            <span>{busy_text(@disk)}</span>
          </div>

          <div class="mb-2 mt-5 flex items-baseline justify-between">
            <h4 class="text-sm font-semibold">Library</h4>
            <span class="text-xs text-base-content/55">{Format.bytes(@disk.free)} free</span>
          </div>
          <ul :if={@rows != []} class="divide-y divide-base-content/10 rounded-field bg-base-200/50">
            <li
              :for={row <- @rows}
              id={"#{@id}-#{row.id}"}
              class="flex flex-wrap items-center gap-x-3 gap-y-2 px-3 py-2.5"
            >
              <.icon
                name={if row.item.kind == :folder, do: "hero-folder", else: "hero-circle-stack"}
                class="size-5 shrink-0 text-base-content/50"
              />
              <div class="min-w-0 flex-1 basis-52">
                <div class="truncate text-sm font-medium" title={row.item.name}>{row.item.name}</div>
                <div class="truncate text-xs text-base-content/55" title={row.detail}>
                  {row.detail}
                </div>
              </div>
              <.badge :if={row.holder} kind={:ok}>{row.holder}</.badge>
              <form
                :if={!row.holder}
                id={"#{@id}-#{row.id}-mode"}
                phx-change="mode"
                phx-target={@myself}
              >
                <input type="hidden" name="name" value={row.item.name} />
                <select
                  name="mode"
                  class="select select-sm w-48"
                  aria-label={"How the computer sees #{row.item.name}"}
                  title={row.hint}
                >
                  <option
                    :for={{value, label} <- row.modes}
                    value={value}
                    selected={value == row.choice}
                  >
                    {label}
                  </option>
                </select>
              </form>
              <.button
                :if={!row.holder}
                size={:sm}
                kind={:primary}
                phx-click="insert"
                phx-value-name={row.item.name}
                phx-target={@myself}
                disabled={@disk.busy != nil or @disk.drives == []}
              >
                Insert
              </.button>
              <div class="dropdown dropdown-end">
                <button
                  type="button"
                  tabindex="0"
                  class="btn btn-square btn-ghost btn-sm"
                  aria-label={"More for #{row.item.name}"}
                >
                  <.icon name="hero-ellipsis-horizontal" class="size-5" />
                </button>
                <ul
                  tabindex="0"
                  class="menu dropdown-content z-10 w-44 rounded-box bg-base-100 p-1 shadow-lg ring-1 ring-base-300/70"
                >
                  <li>
                    <button
                      type="button"
                      class="text-error"
                      phx-click="delete"
                      phx-value-name={row.item.name}
                      phx-target={@myself}
                      disabled={row.locked}
                    >
                      <.icon name="hero-trash" class="size-4" /> Delete
                    </button>
                  </li>
                </ul>
              </div>
            </li>
          </ul>
          <p
            :if={@rows == []}
            class="rounded-field bg-base-200/50 px-3 py-4 text-sm text-base-content/60"
          >
            The library is empty: upload images or a folder.
          </p>

          <div class="mt-3 flex flex-wrap items-center gap-x-6 gap-y-2 text-sm">
            <form
              :if={length(@disk.drives) > 1}
              id={"#{@id}-target"}
              phx-change="target"
              phx-target={@myself}
              class="flex items-center gap-2"
            >
              <span>Insert into</span>
              <select name="drive" class="select select-sm w-auto">
                <option :for={d <- @disk.drives} value={d.drive} selected={d.drive == @target}>
                  {drive_name(@disk, d)}, {if d.medium, do: d.medium.name, else: "empty"}
                </option>
              </select>
            </form>
            <label class="flex cursor-pointer items-center gap-2">
              <input
                type="checkbox"
                class="toggle toggle-success toggle-sm"
                checked={@remember}
                phx-click="remember"
                phx-target={@myself}
              /> Insert it again after the NanoKVM restarts
            </label>
          </div>
        <% end %>

        <div
          id={"#{@id}-upload"}
          phx-hook=".Upload"
          phx-update="ignore"
          phx-target={@myself}
          class="mt-4 flex flex-wrap items-center gap-2"
        >
          <button
            type="button"
            class="btn btn-sm border-0 bg-base-300/80 font-medium shadow-none"
            data-part="addfiles"
          >
            <span class="hero-arrow-up-tray size-4" aria-hidden="true"></span> Upload images…
          </button>
          <button
            type="button"
            class="btn btn-sm border-0 bg-base-300/80 font-medium shadow-none"
            data-part="addfolder"
          >
            <span class="hero-folder-plus size-4" aria-hidden="true"></span> Upload a folder…
          </button>
          <div data-part="status" class="hidden min-w-0 flex-1 items-center gap-2">
            <progress
              data-part="bar"
              class="progress progress-primary h-1.5 w-28 shrink-0"
              max="1"
              value="0"
            ></progress>
            <span data-part="progress" class="min-w-0 truncate text-xs text-base-content/60"></span>
            <button type="button" class="btn btn-ghost btn-xs" data-part="stop">Stop</button>
          </div>
          <input type="file" data-part="files" multiple hidden />
          <input type="file" data-part="folder" webkitdirectory hidden />
        </div>

        <p class="mt-3 text-xs leading-relaxed text-base-content/55">
          An image goes in as what it holds: a disc image on the disc its format belongs on (CD, DVD or
          Blu-ray), any other image as a USB drive; the line under each says what was found, and the
          choice can be forced. A folder goes in as a drive made from it: read-only, the computer sees the
          folder as it was; writable, what the computer changes comes back to the folder when the drive is
          ejected. Folders are exFAT drives, or FAT32 for BIOS updates, UEFI and older systems, which holds
          files of at most 4 GiB. An upload replaces what has its name, unless that is in a drive. Eject
          the drive on the computer before ejecting it here. The library is <code>/data/images</code>
          on the
          NanoKVM, which SFTP reaches too.
        </p>
        <p :if={@error || (@disk && @disk.error)} class="mt-3 text-sm text-error">
          {@error || @disk.error}
        </p>
      </.modal>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Upload">
        export default {
          mounted() {
            const part = (name) => this.el.querySelector(`[data-part="${name}"]`)
            this.part = part
            part("addfiles").addEventListener("click", () => part("files").click())
            part("addfolder").addEventListener("click", () => part("folder").click())
            part("stop").addEventListener("click", () => this.xhr && this.xhr.abort())
            part("files").addEventListener("change", (e) => {
              const entries = [...e.target.files].map((file) => ({file, name: file.name}))
              e.target.value = ""
              this.upload(entries)
            })
            // A folder's files, without hidden ones such as .DS_Store, which the library does not take.
            part("folder").addEventListener("change", (e) => {
              const entries = [...e.target.files]
                .map((file) => ({file, name: file.webkitRelativePath}))
                .filter(({name}) => !name.split("/").some((p) => p.startsWith(".")))
              e.target.value = ""
              this.upload(entries)
            })
          },

          destroyed() {
            if (this.xhr) this.xhr.abort()
          },

          async upload(entries) {
            if (!entries.length || this.xhr) return
            const total = Math.max(entries.reduce((sum, e) => sum + e.file.size, 0), 1)
            let sent = 0, told = Date.now()
            this.busy(true)
            try {
              for (const [i, entry] of entries.entries()) {
                await this.put(entry, (loaded) =>
                  this.show(`${entry.name}, ${i + 1} of ${entries.length}`, (sent + loaded) / total))
                sent += entry.file.size
                if (Date.now() - told > 1000) {
                  told = Date.now()
                  this.pushEventTo(this.el, "uploaded", {})
                }
              }
            } catch (failure) {
              if (failure.code !== "stopped") {
                this.pushEventTo(this.el, "upload_failed", {name: failure.file, error: failure.code})
              }
            } finally {
              this.xhr = null
              this.busy(false)
              this.pushEventTo(this.el, "uploaded", {})
            }
          },

          put({file, name}, progress) {
            return new Promise((resolve, reject) => {
              const xhr = (this.xhr = new XMLHttpRequest())
              const fail = (code) => reject(Object.assign(new Error(code), {code, file: name}))
              xhr.open("PUT", `/api/disk/files?name=${encodeURIComponent(name)}&replace=1`)
              xhr.setRequestHeader("content-type", "application/octet-stream")
              xhr.upload.onprogress = (e) => progress(e.loaded)
              xhr.onload = () => {
                if (xhr.status < 300) return resolve()
                let data = {}
                try { data = JSON.parse(xhr.responseText) } catch (_) {}
                fail(data.error || `HTTP ${xhr.status}`)
              }
              xhr.onerror = () => fail("broken")
              xhr.onabort = () => fail("stopped")
              xhr.send(file)
            })
          },

          busy(on) {
            for (const name of ["addfiles", "addfolder"]) this.part(name).disabled = on
            this.part("status").classList.toggle("hidden", !on)
            this.part("status").classList.toggle("flex", on)
            if (!on) this.show("", 0)
          },

          show(text, fraction) {
            this.part("progress").textContent = text && `${text}: ${Math.floor(100 * fraction)}%`
            this.part("bar").value = fraction
          },
        }
      </script>
    </div>
    """
  end

  defp disk, do: Application.get_env(:kuroneko, :virtual_disk, Kuroneko.VirtualDisk)
end
