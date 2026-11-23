defmodule Kuroneko.VirtualDisk.Maker do
  @moduledoc """
  Another way an item of the library can go in a drive: a module that
  makes an image of its own from it, such as a Windows installer's USB drive
  from the installer's ISO.

  The page lists what each maker offers for an item next to Kuroneko's own
  modes. When one is chosen, Kuroneko gives the maker a path in its work
  directory and runs `c:make/3` in a task of its own, showing its progress;
  then it inserts the image as the maker says and removes it when it comes
  out. A medium that is remembered is made again after a restart.

  Makers are registered in the application environment,

      config :kuroneko, disk_makers: [MyMaker]

  or at run time, until the next restart, with
  `Kuroneko.VirtualDisk.register_maker/1`, from IEx for instance.

      defmodule MyMaker do
        @behaviour Kuroneko.VirtualDisk.Maker

        def id, do: "zeros"

        def offers(%{kind: :image}), do: [%{mode: "zeros", label: "USB drive of zeros"}]
        def offers(_item), do: []

        def make(_item, "zeros", %{image: image, progress: progress}) do
          File.write!(image, :binary.copy(<<0>>, 1_048_576))
          progress.(1_048_576, 1_048_576)
          {:ok, cdrom: false, read_only: true}
        end
      end
  """

  @typedoc """
  An item of the library: its path, whether it is an image file or a
  folder, and what Kuroneko read of an image (`Kuroneko.VirtualDisk.Image`,
  `nil` for a folder).
  """
  @type item() :: %{path: Path.t(), kind: :image | :folder, format: map() | nil}

  @typedoc "A mode a maker offers, by an id of its own and a name the page shows."
  @type offer() :: %{mode: String.t(), label: String.t()}

  @typedoc """
  Where to make the image, how to tell the progress (bytes done of a
  total), and the bytes free on the device for it.
  """
  @type context() :: %{
          image: Path.t(),
          progress: (non_neg_integer(), pos_integer() -> any()),
          free: non_neg_integer()
        }

  @typedoc """
  How the image goes in, as `Kuroneko.Gadget.Storage.insert/2` takes it:
  `cdrom`, `disc`, `tracks`, `read_only`.
  """
  @type insertion() :: keyword()

  @doc "The maker's id, as the API and what is remembered name it: `\"windows-media\"`."
  @callback id() :: String.t()

  @doc """
  The modes it offers for an item, none when it has nothing for it. The
  library is listed often: read little here.
  """
  @callback offers(item()) :: [offer()]

  @doc "Makes the image of an item in a mode it offered, and says how it goes in."
  @callback make(item(), mode :: String.t(), context()) :: {:ok, insertion()} | {:error, term()}

  @doc false
  # What makers offer for an item, each offer with its maker's id; a maker
  # that fails offers nothing.
  @spec offers([module()], item()) :: [%{maker: String.t(), mode: String.t(), label: String.t()}]
  def offers(makers, item) do
    for maker <- makers,
        offer <- safe_offers(maker, item),
        is_binary(offer[:mode]) and is_binary(offer[:label]),
        do: %{maker: maker.id(), mode: offer.mode, label: offer.label}
  end

  defp safe_offers(maker, item) do
    case maker.offers(item) do
      offers when is_list(offers) -> Enum.filter(offers, &is_map/1)
      _other -> []
    end
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  @doc false
  # A module that implements this behaviour.
  @spec maker?(term()) :: boolean()
  def maker?(module) do
    is_atom(module) and Code.ensure_loaded?(module) and function_exported?(module, :id, 0) and
      function_exported?(module, :offers, 1) and function_exported?(module, :make, 3)
  end
end
