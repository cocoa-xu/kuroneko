defmodule Kuroneko.VirtualDisk do
  @moduledoc """
  The virtual disk's library and what is in its drive (`Kuroneko.Gadget.Storage`):
  image files and folders in `/data/images`.

    * An image file goes in as it is: a CD-ROM or a drive, read-only or not.
    * A folder goes in as a FAT32 drive made from it. Read-only, the target
      computer sees the folder as it was. Writable, what the computer changes
      goes back to the folder when the drive is ejected, here or by the
      computer, or at the next start when the NanoKVM restarted with it in.
      FAT32 holds files of at most 4 GiB.

  Making a drive and copying changes back take a while: they run here, one at
  a time, and `state/0` says how far they are.
  """

  use GenServer
  require Logger

  alias Kuroneko.Gadget.Storage
  alias Kuroneko.VirtualDisk.FAT

  @work ".kuroneko"
  @max_file 4 * 1024 * 1024 * 1024 - 1
  # Room the target computer can write to in a writable folder: the image is
  # sparse, so it costs only what is written.
  @writable_room 8 * 1024 * 1024 * 1024
  @keep_free 1024 * 1024 * 1024
  @mount_options "loop,utf8,shortname=mixed"
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
  The library, what is in the drive and what is under way: `%{items:
  [%{name, kind: :image | :folder, size}], medium: nil | %{name, kind,
  cdrom, read_only, image}, busy: nil | %{action: :making | :copying_back,
  name, done, total}, free: bytes, error: nil | text}`.
  """
  @spec state() :: map()
  def state, do: GenServer.call(__MODULE__, :state, 30_000)

  @doc """
  Puts an image file or a folder of the library in the drive. Options:
  `:cdrom` (image files only) and `:read_only`. A folder goes in once its
  drive is made: see `state/0`.
  """
  @spec insert(String.t(), keyword()) :: :ok | {:error, term()}
  def insert(name, opts \\ []), do: GenServer.call(__MODULE__, {:insert, name, opts}, 30_000)

  @doc "Takes the medium out; a writable folder's changes then go back to it."
  @spec eject() :: :ok | {:error, term()}
  def eject, do: GenServer.call(__MODULE__, :eject, 30_000)

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

  @doc "What is in the drive, with the image or folder's name; `nil` when it is empty."
  @spec medium() :: map() | nil
  def medium do
    GenServer.call(__MODULE__, :medium)
  catch
    :exit, _reason ->
      case Storage.medium() do
        {:ok, %{image: image} = medium} -> Map.put(medium, :name, Path.basename(image))
        _empty -> nil
      end
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
    # A 32 KiB cluster, the largest, wasted at most per file, and directory
    # entries for long names.
    needed = bytes + entries * (32 * 1024 + 256) + 16 * 1024 * 1024
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
  def init(_opts),
    do: {:ok, %{medium: nil, busy: nil, task: nil, error: nil}, {:continue, :start}}

  @impl GenServer
  def handle_continue(:start, state) do
    clean_up()
    {:noreply, recover(state)}
  end

  @impl GenServer
  def handle_call(:state, _from, state) do
    state = check_drive(state)

    reply = %{
      items: items(),
      medium: medium(state),
      busy: state.busy,
      free: free_space(),
      error: state.error
    }

    {:reply, reply, state}
  end

  def handle_call(:medium, _from, state), do: {:reply, medium(state), state}

  def handle_call({:writable?, relative}, _from, state),
    do: {:reply, if(in_use?(state, relative), do: {:error, :in_use}, else: :ok), state}

  def handle_call(_request, _from, %{busy: busy} = state) when busy != nil,
    do: {:reply, {:error, :busy}, state}

  def handle_call({:insert, name, opts}, _from, state) do
    state = check_drive(state)

    with :ok <- writable_folder_out(state),
         {:ok, relative} <- library_path(name),
         path = Path.join(dir(), relative),
         {:ok, kind} <- kind(path) do
      case kind do
        :image -> insert_image(state, relative, path, opts)
        :folder -> make_drive(state, relative, path, Keyword.get(opts, :read_only, true))
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:eject, _from, state) do
    case Storage.eject() do
      :ok -> {:reply, :ok, taken_out(state)}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:delete, name}, _from, state) do
    state = check_drive(state)

    with {:ok, relative} <- library_path(name),
         false <- in_use?(state, relative),
         path = Path.join(dir(), relative),
         true <- File.exists?(path) do
      case File.rm_rf(path) do
        {:ok, _removed} -> {:reply, :ok, state}
        {:error, reason, _file} -> {:reply, {:error, reason}, state}
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

  defp finish(state, {:inserted, medium}),
    do: %{state | task: nil, busy: nil, medium: medium, error: nil}

  defp finish(state, :copied_back), do: %{state | task: nil, busy: nil, error: nil}

  defp finish(state, error) do
    Logger.error("virtual disk: #{inspect(state.busy)} failed: #{inspect(error)}")
    %{state | task: nil, busy: nil, error: describe(error)}
  end

  # ---- Image files

  defp insert_image(state, relative, path, opts) do
    cdrom = Keyword.get(opts, :cdrom, String.downcase(Path.extname(path)) == ".iso")
    read_only = Keyword.get(opts, :read_only, cdrom)

    case Storage.insert(path, cdrom: cdrom, read_only: read_only) do
      :ok ->
        state = forget_folder_image(state)
        medium = %{name: relative, kind: :image, read_only: read_only, image: in_drive(path)}
        {:reply, :ok, %{state | medium: medium, error: nil}}

      error ->
        {:reply, error, state}
    end
  end

  # ---- Folders

  defp make_drive(state, relative, folder, read_only) do
    {bytes, entries, largest} = measure(folder)

    with :ok <- if(largest > @max_file, do: {:error, :file_too_large}, else: :ok),
         {:ok, size} <- drive_size(bytes, entries, not read_only, free_space()),
         :ok <- File.mkdir_p(Path.join(dir(), @work)) do
      state = forget_folder_image(state)
      id = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
      image = Path.join([dir(), @work, "#{id}.img"])
      medium = %{name: relative, kind: :folder, read_only: read_only, image: image}
      progress = progress(self(), bytes)

      task =
        Task.async(fn ->
          with :ok <- build(folder, image, size, Path.basename(relative), progress),
               :ok <- write_marker(medium),
               :ok <- Storage.insert(image, cdrom: false, read_only: read_only) do
            {:inserted, %{medium | image: in_drive(image)}}
          else
            error ->
              remove_image(image)
              error
          end
        end)

      busy = %{action: :making, name: relative, done: 0, total: bytes}
      {:reply, :ok, %{state | task: task, busy: busy, error: nil}}
    else
      error -> {:reply, error, state}
    end
  end

  defp build(folder, image, size, label, progress) do
    mount = image <> ".mnt"

    with :ok <- FAT.format(image, size, label: label),
         :ok <- File.mkdir_p(mount),
         :ok <- mount(image, mount, false) do
      try do
        copy_tree(folder, mount, progress)
      after
        unmount(mount)
      end
    end
  end

  # What a writable folder's drive holds goes back to the folder: copied out
  # beside it first, then put in its place, so that a failure keeps the
  # folder as it was.
  defp copy_back(%{image: image, name: relative}, progress_to) do
    folder = Path.join(dir(), relative)
    {mount, fresh, old} = {image <> ".mnt", image <> ".copy", image <> ".old"}

    with :ok <- File.mkdir_p(mount),
         :ok <- mount(image, mount, true),
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

  # Out of the drive, by this page or by the computer: a read-only folder's
  # image goes; a writable one's is copied back to its folder first.
  defp taken_out(%{medium: %{kind: :folder, read_only: false} = medium} = state) do
    server = self()
    task = Task.async(fn -> with :ok <- copy_back(medium, server), do: :copied_back end)
    busy = %{action: :copying_back, name: medium.name, done: 0, total: 0}
    %{state | medium: nil, task: task, busy: busy, error: nil}
  end

  defp taken_out(state), do: %{forget_folder_image(state) | medium: nil}

  defp forget_folder_image(%{medium: %{kind: :folder, read_only: true, image: image}} = state) do
    remove_image(image)
    %{state | medium: nil}
  end

  defp forget_folder_image(state), do: state

  defp writable_folder_out(%{medium: %{kind: :folder, read_only: false}}),
    do: {:error, :eject_first}

  defp writable_folder_out(_state), do: :ok

  # The computer can eject a removable drive itself, which empties it.
  defp check_drive(%{medium: %{image: image}, busy: nil} = state) do
    case Storage.medium() do
      {:ok, %{image: ^image}} -> state
      {:ok, _other} -> taken_out(state)
      {:error, _reason} -> state
    end
  end

  defp check_drive(state), do: state

  # ---- At start

  # The drive may still hold one of our images when only this server
  # restarted. After a restart of the NanoKVM it is empty: a writable
  # folder's image left behind goes back to its folder, a read-only one goes.
  defp recover(state) do
    in_drive =
      case Storage.medium() do
        {:ok, %{image: image}} -> image
        _ -> nil
      end

    Enum.reduce(markers(), state, fn medium, state ->
      cond do
        real_path(medium.image) == in_drive ->
          %{state | medium: %{medium | image: in_drive}}

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

  defp markers do
    for marker <- Path.wildcard(Path.join([dir(), @work, "*.img.json"])),
        {:ok, json} <- [File.read(marker)],
        {:ok, %{"name" => name, "read_only" => read_only}} <- [Jason.decode(json)] do
      %{
        name: name,
        kind: :folder,
        read_only: read_only,
        image: String.trim_trailing(marker, ".json")
      }
    end
  end

  defp write_marker(medium),
    do: File.write(medium.image <> ".json", Jason.encode!(Map.take(medium, [:name, :read_only])))

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

  # The drive reports the file it holds by the path the kernel opened, with
  # links resolved: /root/images for /data/images on Nerves.
  defp in_drive(fallback) do
    case Storage.medium() do
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

  defp items do
    case File.ls(dir()) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            not String.starts_with?(name, "."),
            path = Path.join(dir(), name),
            {:ok, kind} <- [kind(path)] do
          size = if kind == :folder, do: elem(measure(path), 0), else: File.stat!(path).size
          %{name: name, kind: kind, size: size}
        end

      {:error, _reason} ->
        []
    end
  end

  defp kind(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> {:ok, :image}
      {:ok, %{type: :directory}} -> {:ok, :folder}
      {:ok, _other} -> {:error, :invalid_name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp medium(state) do
    case {state.medium, Storage.medium()} do
      {%{image: image} = ours, {:ok, %{image: image} = drive}} ->
        Map.merge(drive, ours)

      {_ours, {:ok, %{image: image} = drive}} ->
        Map.merge(drive, %{name: Path.basename(image), kind: :image})

      _empty ->
        nil
    end
  end

  # A name is in use when it, or a folder holding it, is in the drive or
  # being made into a drive or copied back to.
  defp in_use?(state, relative) do
    names = for %{name: name} <- [state.medium, state.busy], do: name
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
    end
  end

  defp progress(server, total), do: fn done -> send(server, {:progress, done, total}) end

  defp mount(image, mount, read_only) do
    options = if read_only, do: @mount_options <> ",ro", else: @mount_options

    case System.cmd("mount", ["-o", options, "-t", "vfat", image, mount], stderr_to_stdout: true) do
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
  defp describe({:error, reason}), do: inspect(reason)
  defp describe(other), do: inspect(other)

  defp dir, do: Application.get_env(:kuroneko, :virtual_disk_dir, "/data/images")
end
