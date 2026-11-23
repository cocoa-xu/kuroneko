defmodule Kuroneko.VirtualDisk do
  @moduledoc """
  The virtual disk's library and what is in its drives (`Kuroneko.Gadget.MassStorage`):
  image files and folders in `/data/images`. The drives are the LUNs of the
  storage functions, numbered from 0: those of `"disk"` first, then those of
  the others by name (`Kuroneko.USBSettings`).

    * An image file goes in as it is: on the disc its format belongs on, a CD,
      a DVD or a BD (see `Kuroneko.VirtualDisk.Image`), or as a USB drive,
      read-only or not. Any of these can be asked for instead.
    * A folder goes in as a drive made from it: exFAT, or FAT32 for firmware
      (BIOS updates, UEFI) and older systems, which holds files of at most
      4 GiB. Read-only, the target computer sees the folder as it was.
      Writable, what the computer changes goes back to the folder when the
      drive is ejected, here or by the computer, or at the next start when the
      NanoKVM restarted with it in.

  Making a drive and copying changes back take a while: they run here, one at
  a time, and `state/0` says how far they are.

  What is in a drive goes in again when the NanoKVM restarts, unless it was
  inserted with `remember: false`; a folder's drive is not made again then.
  Ejecting it, here or on the computer, forgets it.
  """

  use GenServer
  require Logger

  alias Kuroneko.Gadget.MassStorage
  alias Kuroneko.VirtualDisk.{Cue, ExFAT, FAT, Image, Maker}

  @work ".kuroneko"
  @fat32_max_file 4 * 1024 * 1024 * 1024 - 1
  # Room the target computer can write to in a writable folder: the image is
  # sparse, so it costs only what is written.
  @writable_room 8 * 1024 * 1024 * 1024
  @keep_free 1024 * 1024 * 1024
  # Without utf8, vfat stores names as Latin-1.
  @mount %{exfat: {"exfat", "loop,iocharset=utf8"}, fat32: {"vfat", "loop,utf8,shortname=mixed"}}
  # Characters no exFAT or FAT32 name holds.
  @bad_chars Enum.map(0..31, &<<&1>>) ++ ~w(" * : < > ? \\ |)
  # What the computer's system leaves on a drive, which is not the folder's:
  # it does not go back.
  @system_files [
    ".fseventsd",
    ".Spotlight-V100",
    ".Trashes",
    ".TemporaryItems",
    ".DS_Store",
    "System Volume Information",
    "$RECYCLE.BIN"
  ]

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The library, what is in the drives and what is under way: `%{items:
  [%{name, kind: :image | :folder, size, format, makers}], drives: [%{drive: 0,
  storage: "disk", lun: 0, medium: nil | %{name, kind, cdrom, disc,
  read_only, remember, image}}],
  busy: nil | %{action: :making | :copying_back, name, drive, done, total},
  free: bytes, error: nil | text}`. An image's `format` is what
  `Kuroneko.VirtualDisk.Image.probe/1` finds; `makers`, what makers offer
  for the item (`Kuroneko.VirtualDisk.Maker`): `[%{maker, mode, label}]`.
  """
  @spec state() :: map()
  def state, do: GenServer.call(__MODULE__, :state, 30_000)

  @doc """
  Puts an image file or a folder of the library in a drive. Options:

    * `:drive`: the drive, by default the one that has it already, else the
      first empty one, else the first
    * `:media` (image files): `:auto`, the default, puts an optical disc
      image on its disc and any other image in a USB drive; `:cd`, `:dvd`,
      `:bd` and `:drive` force one
    * `:read_only`: for drives; discs are read-only. By default an optical
      disc image in a USB drive is read-only, other images are not
    * `:filesystem` (folders): `:exfat`, the default, or `:fat32`
    * `:maker` and `:mode`: a registered maker's id and a mode it offers for
      the item: the maker makes the image that goes in
      (`Kuroneko.VirtualDisk.Maker`)
    * `:remember`: `true`, the default, inserts it again after a restart

  A folder, or what a maker makes, goes in once its image is made: see
  `state/0`.
  """
  @spec insert(String.t(), keyword()) :: :ok | {:error, term()}
  def insert(name, opts \\ []), do: GenServer.call(__MODULE__, {:insert, name, opts}, 30_000)

  @doc """
  Registers a maker until the next restart, besides those of the
  `:disk_makers` setting (`Kuroneko.VirtualDisk.Maker`). One of the same id
  is replaced.
  """
  @spec register_maker(module()) :: :ok | {:error, :not_a_maker}
  def register_maker(module), do: GenServer.call(__MODULE__, {:register_maker, module})

  @doc "Takes a drive's medium out; a writable folder's changes then go back to it."
  @spec eject(non_neg_integer()) :: :ok | {:error, term()}
  def eject(drive \\ 0), do: GenServer.call(__MODULE__, {:eject, drive}, 30_000)

  @doc false
  # The drives changed (the USB settings): media of drives gone are out.
  @spec drives_changed() :: :ok
  def drives_changed do
    GenServer.call(__MODULE__, :drives_changed, 30_000)
  catch
    :exit, _not_running -> :ok
  end

  @doc "Deletes an image file or a folder from the library, unless it is in use."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(name), do: GenServer.call(__MODULE__, {:delete, name}, 60_000)

  @doc """
  Where an upload named `path` (`"name.iso"`, or `"folder/sub/file"` for a
  folder's files) goes: `{:ok, final, temporary}`. The caller writes the
  temporary file, then calls `finish_upload/2`. With `replace: true` an
  upload replaces a file of the same name.
  """
  @spec upload_paths(String.t(), keyword()) :: {:ok, Path.t(), Path.t()} | {:error, term()}
  def upload_paths(path, opts \\ []) do
    with {:ok, relative} <- library_path(path),
         final = Path.join(dir(), relative),
         :ok <- if(opts[:replace] || not File.exists?(final), do: :ok, else: {:error, :exists}),
         :ok <- GenServer.call(__MODULE__, {:writable?, relative}),
         :ok <- File.mkdir_p(Path.join(dir(), @work)) do
      {:ok, final, Path.join([dir(), @work, "upload-#{System.unique_integer([:positive])}"])}
    end
  end

  @doc "Moves an uploaded file into the library."
  @spec finish_upload(Path.t(), Path.t()) :: :ok | {:error, term()}
  def finish_upload(temporary, final) do
    with {:error, _reason} = error <- mkdir_rename(temporary, final) do
      File.rm(temporary)
      error
    end
  end

  defp mkdir_rename(from, to) do
    with :ok <- File.mkdir_p(Path.dirname(to)), do: File.rename(from, to)
  end

  @doc """
  What is in each drive, with the image or folder's name and the drive's
  number; `nil` for an empty one.
  """
  @spec media() :: [map() | nil]
  def media do
    GenServer.call(__MODULE__, :media)
  catch
    :exit, _reason ->
      MassStorage.media()
      |> Enum.with_index()
      |> Enum.map(fn
        {%{image: image} = medium, drive} ->
          medium |> page_medium() |> Map.merge(%{name: Path.basename(image), drive: drive})

        {nil, _drive} ->
          nil
      end)
  end

  @doc """
  A path in the library from what the page sends: relative, without `.` or
  `..` parts or hidden names.
  """
  @spec library_path(term()) :: {:ok, Path.t()} | {:error, :invalid_name}
  def library_path(path) when is_binary(path) do
    parts = String.split(path, "/")

    valid? =
      byte_size(path) <= 1024 and String.valid?(path) and
        Enum.all?(parts, fn part ->
          part != "" and byte_size(part) <= 255 and not String.starts_with?(part, ".") and
            not String.contains?(part, <<0>>)
        end)

    if valid?, do: {:ok, Path.join(parts)}, else: {:error, :invalid_name}
  end

  def library_path(_path), do: {:error, :invalid_name}

  @doc """
  The size of a drive made from a folder holding `bytes` in `entries` files
  and folders: their clusters, their directory entries, and room to write
  when `writable`, leaving a GiB of `free` on the NanoKVM.
  """
  @spec drive_size(non_neg_integer(), non_neg_integer(), boolean(), non_neg_integer()) ::
          {:ok, pos_integer()} | {:error, :no_room}
  def drive_size(bytes, entries, writable, free) do
    # A 32 KiB cluster, the largest, wasted at most per file, directory entries
    # for long names, and the FATs: 4 bytes per cluster of 4 KiB or more, twice.
    needed = bytes + entries * (32 * 1024 + 640) + div(bytes, 512) + 16 * 1024 * 1024
    wanted = max(FAT.min_size(), needed + if(writable, do: @writable_room, else: 0))
    available = free - @keep_free

    cond do
      needed > available -> {:error, :no_room}
      wanted > available -> {:ok, round_mib(max(FAT.min_size(), needed))}
      true -> {:ok, round_mib(wanted)}
    end
  end

  defp round_mib(bytes), do: div(bytes + 1024 * 1024 - 1, 1024 * 1024) * 1024 * 1024

  @doc false
  # Bytes, files and folders, and the largest file, under a folder.
  @spec measure(Path.t()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def measure(folder) do
    Enum.reduce(walk(folder), {0, 0, 0}, fn
      {:file, _path, size}, {bytes, entries, largest} ->
        {bytes + size, entries + 1, max(largest, size)}

      {:dir, _path}, {bytes, entries, largest} ->
        {bytes, entries + 1, largest}
    end)
  end

  @doc false
  # The first name under a folder that no drive takes, or nil.
  @spec bad_name(Path.t()) :: Path.t() | nil
  def bad_name(folder) do
    Enum.find_value(walk(folder), fn entry ->
      path = elem(entry, 1)
      if String.contains?(Path.basename(path), @bad_chars), do: Path.relative_to(path, folder)
    end)
  end

  @doc false
  # Copies files and folders, keeping modification times, and says how many
  # bytes are done after each file. Links and devices stay behind.
  @spec copy_tree(Path.t(), Path.t(), (non_neg_integer() -> any()), (String.t() -> boolean())) ::
          :ok | {:error, term()}
  def copy_tree(from, to, progress, skip \\ fn _name -> false end) do
    from
    |> walk(skip)
    |> Enum.reduce_while({:ok, 0}, fn entry, {:ok, done} ->
      case copy_entry(entry, from, to) do
        {:ok, size} ->
          progress.(done + size)
          {:cont, {:ok, done + size}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, _done} -> :ok
      error -> error
    end
  end

  # ---- Server

  @impl GenServer
  def init(_opts) do
    makers = Enum.filter(Application.get_env(:kuroneko, :disk_makers, []), &Maker.maker?/1)
    state = %{media: %{}, busy: nil, task: nil, error: nil, formats: %{}, makers: makers}
    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    clean_up()
    {:noreply, state |> recover() |> insert_remembered()}
  end

  @impl GenServer
  def handle_call(:state, _from, state) do
    state = check_drives(state)
    {items, state} = items(state)

    drives =
      for {{storage, lun} = slot, drive} <- Enum.with_index(slots()) do
        %{drive: drive, storage: storage, lun: lun, medium: view(medium(state, slot), drive)}
      end

    reply = %{
      items: items,
      drives: drives,
      busy: state.busy,
      free: free_space(),
      error: state.error
    }

    {:reply, reply, state}
  end

  def handle_call(:media, _from, state) do
    media = for {slot, drive} <- Enum.with_index(slots()), do: view(medium(state, slot), drive)
    {:reply, media, state}
  end

  def handle_call({:writable?, relative}, _from, state),
    do: {:reply, if(in_use?(state, relative), do: {:error, :in_use}, else: :ok), state}

  def handle_call(:drives_changed, _from, %{busy: nil} = state),
    do: {:reply, :ok, gone(state, Map.keys(state.media) -- slots())}

  def handle_call({:register_maker, module}, _from, state) do
    if Maker.maker?(module) do
      makers = Enum.reject(state.makers, &(&1.id() == module.id())) ++ [module]
      {:reply, :ok, %{state | makers: makers}}
    else
      {:reply, {:error, :not_a_maker}, state}
    end
  end

  def handle_call(_request, _from, %{busy: busy} = state) when busy != nil,
    do: {:reply, {:error, :busy}, state}

  def handle_call({:insert, name, opts}, _from, state) do
    state = check_drives(state)

    with {:ok, relative} <- library_path(name),
         {:ok, drive} <- pick_drive(state, opts[:drive], relative),
         :ok <- writable_folder_out(state, drive),
         path = Path.join(dir(), relative),
         {:ok, kind} <- kind(path) do
      cond do
        opts[:maker] -> make_with(state, drive, relative, path, kind, opts)
        kind == :image -> insert_image(state, drive, relative, path, opts)
        true -> make_drive(state, drive, relative, path, opts)
      end
      |> case do
        {:ok, state} -> {:reply, :ok, state}
        {error, state} -> {:reply, error, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:eject, index}, _from, state) do
    with {:ok, slot} <- drive_slot(index),
         :ok <- MassStorage.eject(at(slot)) do
      {:reply, :ok, taken_out(state, slot)}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:delete, name}, _from, state) do
    state = check_drives(state)

    with {:ok, relative} <- library_path(name),
         false <- in_use?(state, relative),
         path = Path.join(dir(), relative),
         true <- File.exists?(path) do
      case File.rm_rf(path) do
        {:ok, _removed} ->
          for {drive, %{name: ^relative}} <- remembered(), do: forget(drive)
          {:reply, :ok, state}

        {:error, reason, _file} ->
          {:reply, {:error, reason}, state}
      end
    else
      true -> {:reply, {:error, :in_use}, state}
      false -> {:reply, {:error, :enoent}, state}
      error -> {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info({:progress, done, total}, %{busy: busy} = state) when busy != nil,
    do: {:noreply, %{state | busy: %{busy | done: done, total: total}}}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state),
    do: {:noreply, finish(state, {:error, reason})}

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(state, {:inserted, medium}) do
    remember(medium)
    %{put_medium(state, medium) | task: nil, busy: nil, error: nil}
  end

  defp finish(state, :copied_back), do: %{state | task: nil, busy: nil, error: nil}

  defp finish(state, error) do
    Logger.error("virtual disk: #{inspect(state.busy)} failed: #{inspect(error)}")
    %{state | task: nil, busy: nil, error: describe(error)}
  end

  defp put_medium(state, medium), do: put_in(state.media[medium.drive], medium)

  # A medium as the page and the API see it: its drive by number, not by
  # function and LUN.
  defp view(nil, _drive), do: nil
  defp view(medium, drive), do: medium |> Map.delete(:request) |> Map.put(:drive, drive)

  # The drive asked for, else the one with the item, else the first empty
  # one, else the first. An item is in one drive at a time.
  defp pick_drive(state, wanted, relative) do
    slots = slots()
    asked = slot_at(slots, wanted)

    current =
      Enum.find_value(state.media, fn {slot, medium} -> medium.name == relative && slot end)

    cond do
      slots == [] -> {:error, :no_storage}
      wanted != nil and asked == nil -> {:error, :no_drive}
      current != nil and wanted != nil and asked != current -> {:error, :in_use}
      wanted != nil -> {:ok, asked}
      current != nil -> {:ok, current}
      true -> {:ok, Enum.find(slots, hd(slots), &(not Map.has_key?(state.media, &1)))}
    end
  end

  # The drives: each storage function's LUNs, those of "disk" first.
  defp slots do
    Kuroneko.Gadget.instances()
    |> Enum.filter(&(&1.kind == :storage))
    |> Enum.sort_by(&{&1.name != "disk", &1.name})
    |> Enum.flat_map(fn %{name: name, luns: luns} ->
      for lun <- 0..(luns - 1), do: {name, lun}
    end)
  catch
    :exit, _no_gadget -> for lun <- 0..(MassStorage.lun_count() - 1)//1, do: {"disk", lun}
  end

  defp slot_at(slots, index) when is_integer(index) and index >= 0, do: Enum.at(slots, index)
  defp slot_at(_slots, _index), do: nil

  defp drive_slot(index) do
    case slot_at(slots(), index) do
      nil -> {:error, :no_drive}
      slot -> {:ok, slot}
    end
  end

  defp at({storage, lun}), do: [name: storage, lun: lun]

  # The page tells a drive by whether it is optical and the disc it holds.
  defp page_medium(%{as: as} = medium) do
    medium
    |> Map.delete(:as)
    |> Map.merge(%{cdrom: as != :disk, disc: if(as != :disk, do: as)})
  end

  defp inserted_as(insertion) do
    as = Keyword.get(insertion, :as, :disk)

    %{
      cdrom: as != :disk,
      disc: if(as != :disk, do: as),
      read_only: Keyword.get(insertion, :read_only, as != :disk)
    }
  end

  defp index(slot), do: Enum.find_index(slots(), &(&1 == slot))

  # ---- Image files

  defp insert_image(state, drive, relative, path, opts) do
    if cue?(path),
      do: insert_cue(state, drive, relative, path, opts),
      else: insert_plain_image(state, drive, relative, path, opts)
  end

  defp insert_plain_image(state, drive, relative, path, opts) do
    {format, entry} = cached_format(state.formats, path)
    state = put_in(state.formats[path], entry)
    disc = disc(Keyword.get(opts, :media, :auto), format)
    read_only = disc != nil or Keyword.get(opts, :read_only, format.disc != nil)

    case MassStorage.insert(path, at(drive) ++ [as: disc || :disk, read_only: read_only]) do
      :ok ->
        state = forget_folder_image(state, drive)

        medium = %{
          name: relative,
          kind: :image,
          drive: drive,
          cdrom: disc != nil,
          disc: disc,
          read_only: read_only,
          remember: Keyword.get(opts, :remember, true),
          request: Keyword.take(opts, [:media, :read_only]),
          image: in_drive(drive, path)
        }

        remember(medium)
        {:ok, %{put_medium(state, medium) | error: nil}}

      error ->
        {error, state}
    end
  end

  # ---- CUE sheets: a CD of tracks, from one BIN as it is or laid out anew

  defp cue?(path), do: String.downcase(Path.extname(path)) == ".cue"

  defp insert_cue(state, drive, relative, path, opts) do
    with :ok <-
           if(Keyword.get(opts, :media, :auto) in [:auto, :cd], do: :ok, else: {:error, :cd_only}),
         {:ok, tracks} <- read_cue(path),
         {:ok, layout} <- cue_result(Cue.layout(tracks)) do
      case layout do
        {:direct, bin, table} ->
          with :ok <- MassStorage.insert(bin, at(drive) ++ [tracks: table, read_only: true]) do
            state = forget_folder_image(state, drive)
            medium = cue_medium(relative, drive, table, in_drive(drive, bin), opts)
            remember(medium)
            {:ok, %{put_medium(state, medium) | error: nil}}
          end

        {:layout, pieces, table} ->
          make_disc(state, drive, relative, pieces, table, opts)
      end
    end
    |> case do
      {:ok, state} -> {:ok, state}
      error -> {error, state}
    end
  end

  defp read_cue(path) do
    with {:ok, text} <- File.read(path),
         do: cue_result(Cue.parse(text, Path.dirname(path)))
  end

  defp cue_result({:error, reason}) when is_atom(reason) and reason != :enoent,
    do: {:error, {:cue, cue_text(reason)}}

  defp cue_result({:error, reason}) when is_tuple(reason), do: {:error, {:cue, cue_text(reason)}}
  defp cue_result(result), do: result

  defp cue_text({:line, line, reason}), do: "line #{line}: #{cue_text(reason)}"
  defp cue_text({:track, {number, reason}}), do: "track #{number}: #{cue_text(reason)}"
  defp cue_text({file, reason}) when is_binary(file), do: "#{file}: #{cue_text(reason)}"
  defp cue_text(:enoent), do: "not in the library"
  defp cue_text(:not_cd_audio), do: "not CD audio (44.1 kHz, 16 bits, stereo)"
  defp cue_text(:no_index_1), do: "no INDEX 01"
  defp cue_text(:index_order), do: "indexes out of order"
  defp cue_text(:number), do: "tracks out of order"
  defp cue_text(:no_tracks), do: "no tracks"
  defp cue_text(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp cue_medium(relative, drive, table, image, opts) do
    %{
      name: relative,
      kind: :image,
      drive: drive,
      cdrom: true,
      disc: :cd,
      tracks: length(table),
      read_only: true,
      remember: Keyword.get(opts, :remember, true),
      request: Keyword.take(opts, [:media]),
      image: image
    }
  end

  # The tracks of a sheet laid out as one image in the work directory, as a
  # folder's drive is made.
  defp make_disc(state, drive, relative, pieces, table, opts) do
    bytes = Cue.size(pieces)

    with :ok <- if(bytes + @keep_free <= free_space(), do: :ok, else: {:error, :no_room}),
         :ok <- File.mkdir_p(Path.join(dir(), @work)) do
      state = forget_folder_image(state, drive)
      id = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
      image = Path.join([dir(), @work, "#{id}.img"])
      medium = Map.put(cue_medium(relative, drive, table, image, opts), :made, true)
      progress = progress(self(), bytes)

      task =
        Task.async(fn ->
          with :ok <- Cue.write(pieces, image, &progress.(&1)),
               :ok <- write_marker(medium),
               :ok <- MassStorage.insert(image, at(drive) ++ [tracks: table, read_only: true]) do
            {:inserted, %{medium | image: in_drive(drive, image)}}
          else
            error ->
              remove_image(image)
              error
          end
        end)

      busy = %{action: :making, name: relative, drive: index(drive), done: 0, total: bytes}
      {:ok, %{state | task: task, busy: busy, error: nil}}
    end
  end

  # ---- Makers: an image another module makes from an item

  defp make_with(state, drive, relative, path, kind, opts) do
    with {:ok, maker} <- find_maker(state, opts[:maker]),
         format = if(kind == :image, do: elem(cached_format(state.formats, path), 0)),
         item = %{path: path, kind: kind, format: format},
         {:ok, offer} <- find_offer(maker, item, opts[:mode]),
         :ok <- File.mkdir_p(Path.join(dir(), @work)) do
      state = forget_folder_image(state, drive)
      id = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
      image = Path.join([dir(), @work, "#{id}.img"])
      server = self()

      medium = %{
        name: relative,
        kind: kind,
        drive: drive,
        made: true,
        maker: maker.id(),
        mode: offer.mode,
        label: offer.label,
        cdrom: false,
        read_only: true,
        remember: Keyword.get(opts, :remember, true),
        request: Keyword.take(opts, [:maker, :mode]),
        image: image
      }

      context = %{
        image: image,
        progress: fn done, total -> send(server, {:progress, done, total}) end,
        free: max(free_space() - @keep_free, 0),
        format_fat: &Kuroneko.VirtualDisk.FAT.format/3
      }

      task =
        Task.async(fn ->
          with {:ok, insertion} <- run_maker(maker, item, offer.mode, context),
               medium =
                 Map.merge(medium, inserted_as(insertion)),
               :ok <- write_marker(medium),
               :ok <- MassStorage.insert(image, at(drive) ++ insertion) do
            {:inserted, %{medium | image: in_drive(drive, image)}}
          else
            error ->
              remove_image(image)
              error
          end
        end)

      busy = %{action: :making, name: relative, drive: index(drive), done: 0, total: 0}
      {:ok, %{state | task: task, busy: busy, error: nil}}
    else
      error -> {error, state}
    end
  end

  defp find_maker(state, id) do
    case Enum.find(state.makers, &(&1.id() == id)) do
      nil -> {:error, :no_maker}
      maker -> {:ok, maker}
    end
  end

  defp find_offer(maker, item, mode) do
    case Enum.find(Maker.offers([maker], item), &(&1.mode == mode)) do
      nil -> {:error, :not_offered}
      offer -> {:ok, offer}
    end
  end

  # A maker that raises fails the making, not the server.
  defp run_maker(maker, item, mode, context) do
    case maker.make(item, mode, context) do
      {:ok, insertion} when is_list(insertion) -> {:ok, insertion}
      {:error, reason} -> {:error, {:maker, maker.id(), reason}}
      other -> {:error, {:maker, maker.id(), other}}
    end
  rescue
    error -> {:error, {:maker, maker.id(), Exception.message(error)}}
  end

  # What the page shows of a sheet: its tracks, or why the drive cannot take it.
  defp cue_format(path) do
    case read_cue(path) do
      {:ok, tracks} ->
        audio = Enum.count(tracks, &(&1.mode == :audio))
        %{disc: :cd, cue: %{audio: audio, data: length(tracks) - audio}}

      {:error, {:cue, text}} ->
        %{disc: nil, cue: %{error: text}}

      {:error, reason} ->
        %{disc: nil, cue: %{error: cue_text(reason)}}
    end
  end

  # The disc an image goes in on, nil for a USB drive.
  defp disc(:auto, format), do: format.disc
  defp disc(:drive, _format), do: nil
  defp disc(disc, _format) when disc in [:cd, :dvd, :bd], do: disc

  # What an image holds, and the cache entry for it: read again only when
  # the file changed.
  defp cached_format(formats, path) do
    case {File.stat(path, time: :posix), formats[path]} do
      {{:ok, %{mtime: mtime, size: size}}, {mtime, size, format} = entry} ->
        {format, entry}

      {{:ok, %{mtime: mtime, size: size}}, _stale} ->
        format =
          case cue?(path) || Image.probe(path) do
            true -> cue_format(path)
            {:ok, format} -> format
            {:error, _reason} -> %{disc: nil}
          end

        {format, {mtime, size, format}}

      {{:error, _reason}, _cached} ->
        {%{disc: nil}, nil}
    end
  end

  # ---- Folders

  defp make_drive(state, drive, relative, folder, opts) do
    read_only = Keyword.get(opts, :read_only, true)
    filesystem = Keyword.get(opts, :filesystem, :exfat)
    {bytes, entries, largest} = measure(folder)

    with :ok <- holds(filesystem, largest),
         :ok <- if(name = bad_name(folder), do: {:error, {:bad_name, name}}, else: :ok),
         {:ok, size} <- drive_size(bytes, entries, not read_only, free_space()),
         :ok <- File.mkdir_p(Path.join(dir(), @work)) do
      state = forget_folder_image(state, drive)
      id = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
      image = Path.join([dir(), @work, "#{id}.img"])

      medium = %{
        name: relative,
        kind: :folder,
        drive: drive,
        filesystem: filesystem,
        read_only: read_only,
        remember: Keyword.get(opts, :remember, true),
        image: image
      }

      progress = progress(self(), bytes)

      task =
        Task.async(fn ->
          with :ok <- build(folder, image, size, medium, progress),
               :ok <- write_marker(medium),
               :ok <- MassStorage.insert(image, at(drive) ++ [as: :disk, read_only: read_only]) do
            {:inserted, %{medium | image: in_drive(drive, image)}}
          else
            error ->
              remove_image(image)
              error
          end
        end)

      busy = %{action: :making, name: relative, drive: index(drive), done: 0, total: bytes}
      {:ok, %{state | task: task, busy: busy, error: nil}}
    else
      error -> {error, state}
    end
  end

  defp holds(:exfat, _largest), do: if(ExFAT.available?(), do: :ok, else: {:error, :no_exfat})
  defp holds(:fat32, largest) when largest > @fat32_max_file, do: {:error, :file_too_large}
  defp holds(:fat32, _largest), do: :ok

  defp build(folder, image, size, medium, progress) do
    mount = image <> ".mnt"
    label = Path.basename(medium.name)

    with :ok <- format(medium.filesystem, image, size, label),
         :ok <- File.mkdir_p(mount),
         :ok <- mount(image, mount, medium.filesystem, false) do
      try do
        copy_tree(folder, mount, progress)
      after
        unmount(mount)
      end
    end
  end

  defp format(:exfat, image, size, label), do: ExFAT.format(image, size, label: label)
  defp format(:fat32, image, size, label), do: FAT.format(image, size, label: label)

  # What a writable folder's drive holds goes back to the folder: copied out
  # beside it first, then put in its place, so that a failure keeps the
  # folder as it was.
  defp copy_back(%{image: image, name: relative, filesystem: filesystem}, progress_to) do
    folder = Path.join(dir(), relative)
    {mount, fresh, old} = {image <> ".mnt", image <> ".copy", image <> ".old"}

    with :ok <- File.mkdir_p(mount),
         :ok <- mount(image, mount, filesystem, true),
         :ok <- copy_out(mount, fresh, progress_to),
         :ok <- if(File.exists?(folder), do: File.rename(folder, old), else: :ok),
         :ok <- File.mkdir_p(Path.dirname(folder)),
         :ok <- File.rename(fresh, folder) do
      File.rm_rf(old)
      remove_image(image)
    end
  end

  defp copy_out(mount, fresh, progress_to) do
    {bytes, _entries, _largest} = measure(mount)
    File.rm_rf(fresh)

    with :ok <- File.mkdir_p(fresh),
         do: copy_tree(mount, fresh, progress(progress_to, bytes), &system_file?/1)
  after
    unmount(mount)
  end

  # Out of a drive, by this page or by the computer: a read-only folder's
  # image goes; a writable one's is copied back to its folder first, or at
  # the next start when another copy runs.
  defp taken_out(state, drive) do
    forget(drive)

    case state.media[drive] do
      %{kind: :folder, read_only: false} = medium when state.busy == nil ->
        server = self()
        task = Task.async(fn -> with :ok <- copy_back(medium, server), do: :copied_back end)
        busy = %{action: :copying_back, name: medium.name, drive: index(drive), done: 0, total: 0}
        %{state | media: Map.delete(state.media, drive), task: task, busy: busy, error: nil}

      %{kind: :folder, read_only: false} ->
        %{state | media: Map.delete(state.media, drive)}

      _image_or_read_only ->
        state = forget_folder_image(state, drive)
        %{state | media: Map.delete(state.media, drive)}
    end
  end

  # Drives that are no longer there.
  defp gone(state, drives), do: Enum.reduce(drives, state, &taken_out(&2, &1))

  defp forget_folder_image(state, drive) do
    case state.media[drive] do
      %{kind: :folder, read_only: true, image: image} ->
        remove_image(image)
        %{state | media: Map.delete(state.media, drive)}

      %{made: true, image: image} ->
        remove_image(image)
        %{state | media: Map.delete(state.media, drive)}

      _other ->
        state
    end
  end

  defp writable_folder_out(state, drive) do
    if match?(%{kind: :folder, read_only: false}, state.media[drive]),
      do: {:error, :eject_first},
      else: :ok
  end

  # The computer can eject a removable drive itself, which empties it.
  defp check_drives(%{busy: nil} = state) do
    Enum.reduce_while(state.media, state, fn {drive, %{image: image}}, state ->
      case MassStorage.medium(at(drive)) do
        {:ok, %{image: ^image}} ->
          {:cont, state}

        {:ok, _other} ->
          state |> taken_out(drive) |> then(&{if(&1.busy, do: :halt, else: :cont), &1})

        {:error, _reason} ->
          {:cont, state}
      end
    end)
  end

  defp check_drives(state), do: state

  # ---- At start

  # A drive may still hold one of our images when only this server
  # restarted. After a restart of the NanoKVM the drives are empty: a
  # remembered folder's image goes in again; another writable folder's
  # image left behind goes back to its folder, a read-only one goes.
  defp recover(state) do
    remembered = remembered()

    Enum.reduce(markers(), state, fn medium, state ->
      drive = medium.drive
      in_drive = in_drive(drive, nil)
      memory = remembered[drive]

      cond do
        real_path(medium.image) == in_drive ->
          put_medium(state, %{medium | image: in_drive})

        match?(%{kind: :folder}, memory) and memory.name == medium.name and drive in slots() and
            MassStorage.insert(
              medium.image,
              at(drive) ++ [as: :disk, read_only: medium.read_only]
            ) ==
              :ok ->
          put_medium(state, %{medium | image: in_drive(drive, medium.image)})

        medium.read_only ->
          remove_image(medium.image)
          state

        true ->
          with {:error, reason} <- copy_back(medium, self()) do
            Logger.error("virtual disk: #{medium.name} not copied back: #{inspect(reason)}")
          end

          state
      end
    end)
  end

  defp insert_remembered(state) do
    remembered()
    |> Enum.sort()
    |> Enum.reduce(state, fn {drive, memory}, state ->
      if Map.has_key?(state.media, drive) or state.busy != nil or drive not in slots(),
        do: state,
        else: insert_again(state, drive, memory)
    end)
  end

  defp insert_again(state, drive, %{name: name, opts: opts}) do
    with {:ok, relative} <- library_path(name),
         path = Path.join(dir(), relative),
         {:ok, kind} <- kind(path) do
      inserted =
        cond do
          opts[:maker] ->
            make_with(state, drive, relative, path, kind, opts)

          kind == :image and real_path(path) == in_drive(drive, nil) ->
            {:ok, adopt_image(state, drive, relative, opts)}

          kind == :image ->
            insert_image(state, drive, relative, path, opts)

          true ->
            make_drive(state, drive, relative, path, opts)
        end

      case inserted do
        {:ok, state} ->
          state

        {error, state} ->
          Logger.error("virtual disk: #{name} not inserted again: #{inspect(error)}")
          state
      end
    else
      _gone -> state
    end
  end

  # Still in the drive when only this server restarted: kept as it is, so
  # that the computer sees no change of medium.
  defp adopt_image(state, drive, relative, opts) do
    {:ok, inserted} = MassStorage.medium(at(drive))

    medium =
      Map.merge(page_medium(inserted), %{
        name: relative,
        kind: :image,
        drive: drive,
        remember: true,
        request: Keyword.take(opts, [:media, :read_only])
      })

    put_medium(state, medium)
  end

  # What goes in again at the next start, each drive's as it was asked for.
  defp remember(%{remember: false, drive: drive}), do: forget(drive)

  defp remember(medium) do
    opts =
      if medium.kind == :folder,
        do: [filesystem: medium.filesystem, read_only: medium.read_only],
        else: medium.request

    save_memory(
      Map.put(remembered(), medium.drive, %{name: medium.name, kind: medium.kind, opts: opts})
    )
  end

  defp forget(drive) do
    remembered = remembered()
    if Map.has_key?(remembered, drive), do: save_memory(Map.delete(remembered, drive)), else: :ok
  end

  defp remembered do
    with {:ok, json} <- File.read(memory_file()),
         {:ok, fields} <- Jason.decode(json) do
      drives =
        case fields do
          %{"drives" => drives} when is_map(drives) -> drives
          # One drive's, from before there were several.
          %{"name" => _name} -> %{"disk/0" => fields}
          _other -> %{}
        end

      for {id, entry} <- drives,
          slot = slot_of(id),
          slot != nil,
          {:ok, memory} <- [from_memory(entry)],
          into: %{},
          do: {slot, memory}
    else
      _none -> %{}
    end
  end

  # "boot/1", or "1" for disk's LUN 1, as kept before there were several
  # storage functions.
  defp slot_of(id) do
    with [storage, lun] <-
           (case String.split(id, "/") do
              [lun] -> ["disk", lun]
              parts -> parts
            end),
         {lun, ""} <- Integer.parse(lun) do
      {storage, lun}
    else
      _invalid -> nil
    end
  end

  defp save_memory(memories) when memories == %{}, do: File.rm(memory_file())

  defp save_memory(memories) do
    path = memory_file()

    drives =
      for {{storage, lun}, %{name: name, kind: kind, opts: opts}} <- memories,
          into: %{},
          do: {"#{storage}/#{lun}", memory(name, kind, opts)}

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", Jason.encode!(%{drives: drives})),
         do: File.rename(path <> ".tmp", path)
  end

  @doc false
  # The JSON kept for an insertion, and back.
  @spec memory(String.t(), :image | :folder, keyword()) :: map()
  def memory(name, kind, opts),
    do: %{"name" => name, "kind" => kind, "opts" => Map.new(opts, fn {k, v} -> {k, v} end)}

  @memory_values %{
    "media" => %{"auto" => :auto, "cd" => :cd, "dvd" => :dvd, "bd" => :bd, "drive" => :drive},
    "filesystem" => %{"exfat" => :exfat, "fat32" => :fat32}
  }

  @doc false
  @spec from_memory(map()) :: {:ok, map()} | :error
  def from_memory(%{"name" => name, "kind" => kind, "opts" => opts})
      when is_binary(name) and kind in ["image", "folder"] and is_map(opts) do
    choices =
      for {field, values} <- @memory_values,
          value = values[opts[field]],
          value != nil,
          do: {String.to_existing_atom(field), value}

    flags = for key <- ["read_only"], is_boolean(opts[key]), do: {:read_only, opts[key]}

    made =
      for key <- ["maker", "mode"],
          is_binary(opts[key]),
          do: {String.to_existing_atom(key), opts[key]}

    {:ok, %{name: name, kind: String.to_existing_atom(kind), opts: choices ++ flags ++ made}}
  end

  def from_memory(_fields), do: :error

  defp memory_file,
    do: Application.get_env(:kuroneko, :virtual_disk_memory, "/data/kuroneko/disk.json")

  defp markers do
    for marker <- Path.wildcard(Path.join([dir(), @work, "*.img.json"])),
        {:ok, json} <- [File.read(marker)],
        {:ok, %{"name" => name, "read_only" => read_only} = fields} <- [Jason.decode(json)] do
      medium = %{
        name: name,
        kind: :folder,
        drive: marker_slot(fields),
        filesystem: if(fields["filesystem"] == "fat32", do: :fat32, else: :exfat),
        read_only: read_only,
        remember: fields["remember"] == true,
        image: String.trim_trailing(marker, ".json")
      }

      # A CUE sheet's image, or a maker's
      case fields["kind"] do
        "cue" ->
          medium
          |> Map.drop([:filesystem])
          |> Map.merge(%{kind: :image, made: true, cdrom: true, disc: :cd})

        "made" ->
          medium
          |> Map.drop([:filesystem])
          |> Map.merge(%{
            kind: :image,
            made: true,
            cdrom: fields["cdrom"] == true,
            maker: fields["maker"]
          })

        _folder ->
          medium
      end
    end
  end

  defp marker_slot(%{"storage" => storage, "lun" => lun})
       when is_binary(storage) and is_integer(lun),
       do: {storage, lun}

  defp marker_slot(%{"drive" => lun}) when is_integer(lun), do: {"disk", lun}
  defp marker_slot(_fields), do: {"disk", 0}

  defp write_marker(medium) do
    {storage, lun} = medium.drive

    fields =
      medium
      |> Map.take([:name, :filesystem, :read_only, :remember])
      |> Map.merge(%{storage: storage, lun: lun})
      |> Map.merge(made_fields(medium))

    File.write(medium.image <> ".json", Jason.encode!(fields))
  end

  defp made_fields(%{made: true, maker: maker} = medium),
    do: %{kind: "made", maker: maker, cdrom: medium.cdrom}

  defp made_fields(%{made: true}), do: %{kind: "cue"}
  defp made_fields(_folder), do: %{}

  defp remove_image(image) do
    File.rm(image)
    File.rm(image <> ".json")
    :ok
  end

  # Uploads cut off and mount points of a stopped server.
  defp clean_up do
    for path <- Path.wildcard(Path.join([dir(), @work, "*"])) do
      cond do
        String.starts_with?(Path.basename(path), "upload-") -> File.rm(path)
        String.ends_with?(path, ".mnt") -> unmount(path)
        String.ends_with?(path, ".copy") -> File.rm_rf(path)
        true -> :ok
      end
    end
  end

  # A drive reports the file it holds by the path the kernel opened, with
  # links resolved: /root/images for /data/images on Nerves.
  defp in_drive(drive, fallback) do
    case MassStorage.medium(at(drive)) do
      {:ok, %{image: image}} -> image
      _empty -> fallback
    end
  end

  @doc false
  @spec real_path(Path.t()) :: Path.t()
  def real_path(path, depth \\ 0) do
    [root | parts] = path |> Path.expand() |> Path.split()
    resolve(parts, root, depth)
  end

  defp resolve([], resolved, _depth), do: resolved

  defp resolve([part | rest], resolved, depth) do
    path = Path.join(resolved, part)

    case File.read_link(path) do
      {:ok, target} when depth < 20 ->
        real_path(Path.join([Path.expand(target, resolved) | rest]), depth + 1)

      _not_a_link ->
        resolve(rest, path, depth)
    end
  end

  # ---- Library

  defp items(state) do
    names =
      case File.ls(dir()) do
        {:ok, names} -> Enum.sort(names)
        {:error, _reason} -> []
      end

    entries =
      for name <- names,
          not String.starts_with?(name, "."),
          path = Path.join(dir(), name),
          {:ok, kind} <- [kind(path)],
          do: {name, path, kind}

    {items, formats} =
      Enum.map_reduce(entries, %{}, fn
        {name, path, :folder}, formats ->
          makers = Maker.offers(state.makers, %{path: path, kind: :folder, format: nil})
          {%{name: name, kind: :folder, size: elem(measure(path), 0), makers: makers}, formats}

        {name, path, :image}, formats ->
          {format, entry} = cached_format(state.formats, path)
          makers = Maker.offers(state.makers, %{path: path, kind: :image, format: format})

          item = %{
            name: name,
            kind: :image,
            size: File.stat!(path).size,
            format: format,
            makers: makers
          }

          {item, Map.put(formats, path, entry)}
      end)

    {items, %{state | formats: formats}}
  end

  defp kind(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> {:ok, :image}
      {:ok, %{type: :directory}} -> {:ok, :folder}
      {:ok, _other} -> {:error, :invalid_name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp medium(state, {storage, lun} = slot) do
    case {state.media[slot],
          with(
            {:ok, inserted} <- MassStorage.medium(at(slot)),
            do: {:ok, inserted |> page_medium() |> count_tracks()}
          )} do
      {%{image: image} = ours, {:ok, %{image: image} = inserted}} ->
        inserted
        |> Map.merge(Map.delete(ours, :drive))
        |> Map.merge(%{storage: storage, lun: lun})

      {_ours, {:ok, %{image: image} = inserted}} ->
        Map.merge(inserted, %{
          name: Path.basename(image),
          kind: :image,
          storage: storage,
          lun: lun,
          remember: false
        })

      _empty ->
        nil
    end
  end

  # The drive tells each track; the page and the API, how many.
  defp count_tracks(%{tracks: tracks} = medium) when is_list(tracks),
    do: %{medium | tracks: length(tracks)}

  defp count_tracks(medium), do: medium

  # A name is in use when it, or a folder holding it, is in a drive or being
  # made into a drive or copied back to.
  defp in_use?(state, relative) do
    names = for %{name: name} <- [state.busy | Map.values(state.media)], do: name
    top = relative |> Path.split() |> hd()
    Enum.any?(names, &(&1 == relative or &1 == top or String.starts_with?(relative, &1 <> "/")))
  end

  @doc false
  @spec system_file?(String.t()) :: boolean()
  def system_file?(name), do: name in @system_files or String.starts_with?(name, "._")

  defp walk(folder, skip \\ fn _name -> false end) do
    case File.ls(folder) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(folder, name)

          case if(skip.(name), do: :skip, else: File.lstat(path)) do
            {:ok, %{type: :directory}} -> [{:dir, path} | walk(path, skip)]
            {:ok, %{type: :regular, size: size}} -> [{:file, path, size}]
            _link_or_device -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp copy_entry({:dir, path}, from, to) do
    with :ok <- File.mkdir_p(Path.join(to, Path.relative_to(path, from))), do: {:ok, 0}
  end

  defp copy_entry({:file, path, size}, from, to) do
    target = Path.join(to, Path.relative_to(path, from))

    with {:ok, _bytes} <- File.copy(path, target),
         {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         :ok <- File.touch(target, mtime) do
      {:ok, size}
    else
      {:error, reason} -> {:error, {:copy, Path.relative_to(path, from), reason}}
    end
  end

  defp progress(server, total), do: fn done -> send(server, {:progress, done, total}) end

  defp mount(image, mount, filesystem, read_only) do
    {type, options} = Map.fetch!(@mount, filesystem)
    options = if read_only, do: options <> ",ro", else: options

    case System.cmd("mount", ["-o", options, "-t", type, image, mount], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:mount, String.trim(output)}}
    end
  end

  defp unmount(mount) do
    System.cmd("umount", [mount], stderr_to_stdout: true)
    File.rmdir(mount)
    :ok
  end

  defp free_space do
    case System.cmd("df", ["-k", existing_parent(dir())], stderr_to_stdout: true) do
      {output, 0} ->
        case output |> String.split("\n", trim: true) |> List.last() |> String.split() do
          [_fs, _size, _used, available | _rest] -> String.to_integer(available) * 1024
          _other -> 0
        end

      _error ->
        0
    end
  rescue
    _error -> 0
  end

  defp existing_parent(path),
    do: if(File.exists?(path), do: path, else: existing_parent(Path.dirname(path)))

  defp describe({:error, {:mount, output}}), do: "the drive could not be mounted: #{output}"
  defp describe({:error, {:mkfs, output}}), do: "the drive could not be made: #{output}"

  defp describe({:error, {:copy, path, reason}}),
    do: "#{path} could not be copied: #{:file.format_error(reason)}"

  defp describe({:error, {:maker, id, reason}}) when is_binary(reason), do: "#{id}: #{reason}"
  defp describe({:error, {:maker, id, reason}}), do: "#{id}: #{inspect(reason)}"
  defp describe({:error, reason}), do: inspect(reason)
  defp describe(other), do: inspect(other)

  defp dir, do: Application.get_env(:kuroneko, :virtual_disk_dir, "/data/images")
end
