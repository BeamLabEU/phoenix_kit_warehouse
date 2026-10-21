defmodule PhoenixKitWarehouse.InventoryAI.Photos do
  @moduledoc """
  The photos of a run, made ready for the call (spec §10.1).

  Each photo is made again from its original in Storage, never from a
  variant (the variants' sizes are a site setting, and right after an upload
  they are usually not there yet): `PhoenixKit.Modules.Storage.ImageProcessor.preview_jpeg/3`
  gives a JPEG at most 2000 px on its long side, turned by its EXIF
  orientation, a HEIC photo included. A photo that cannot be read (not an
  image, a broken file, gone from Storage) is skipped and reported; the
  numbering of the photos the model sees is the order of those that are
  left. The sum of the bytes is checked before the call (80 MB, well under
  ai's 100 MB). The copy of the original and the JPEG are temporary files,
  removed as soon as the bytes are read.
  """

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ImageProcessor

  @max_edge 2000
  @max_total_bytes 80_000_000

  @type prepared :: %{
          images: [%{data: binary(), content_type: String.t()}],
          file_uuids: [String.t()],
          skipped: [%{String.t() => String.t()}]
        }

  @doc "The long side of a prepared photo, in pixels."
  @spec max_edge() :: pos_integer()
  def max_edge, do: @max_edge

  @doc "The most bytes the prepared photos of one run may sum to."
  @spec max_total_bytes() :: pos_integer()
  def max_total_bytes, do: @max_total_bytes

  @doc """
  Prepares the Storage files `file_uuids`, in order.

  `{:ok, %{images, file_uuids, skipped}}` - `images` and `file_uuids` in the
  same order (the numbering of the photos), `skipped` as
  `%{"file_uuid", "reason"}`. `{:error, :no_photos}` when none could be
  read, `{:error, {:too_large, bytes, max}}` past the byte limit.

  Options: `:max_total_bytes`; `:retrieve` - how an original is fetched
  (`Storage.retrieve_file/1` by default: a temporary copy, which is removed
  here).
  """
  @spec prepare([String.t()], keyword()) ::
          {:ok, prepared()} | {:error, :no_photos | {:too_large, pos_integer(), pos_integer()}}
  def prepare(file_uuids, opts \\ []) do
    retrieve = Keyword.get(opts, :retrieve, &Storage.retrieve_file/1)
    max_total = Keyword.get(opts, :max_total_bytes, @max_total_bytes)

    {ready, skipped} =
      Enum.reduce(file_uuids, {[], []}, fn uuid, {ready, skipped} ->
        case prepare_one(uuid, retrieve) do
          {:ok, data} -> {[{uuid, data} | ready], skipped}
          {:error, reason} -> {ready, [%{"file_uuid" => uuid, "reason" => reason} | skipped]}
        end
      end)

    ready = Enum.reverse(ready)
    total = ready |> Enum.map(&byte_size(elem(&1, 1))) |> Enum.sum()

    cond do
      ready == [] ->
        {:error, :no_photos}

      total > max_total ->
        {:error, {:too_large, total, max_total}}

      true ->
        {:ok,
         %{
           images:
             Enum.map(ready, fn {_uuid, data} -> %{data: data, content_type: "image/jpeg"} end),
           file_uuids: Enum.map(ready, &elem(&1, 0)),
           skipped: Enum.reverse(skipped)
         }}
    end
  end

  defp prepare_one(uuid, retrieve) do
    case retrieve.(uuid) do
      {:ok, original, _file} -> convert(uuid, original)
      {:error, reason} -> skip(uuid, "not retrieved: #{reason_text(reason)}")
    end
  rescue
    exception -> skip(uuid, "not retrieved: #{inspect(exception.__struct__)}")
  catch
    :exit, _reason -> skip(uuid, "not retrieved: exit")
  end

  defp convert(uuid, original) do
    output =
      Path.join(System.tmp_dir!(), "pkw-inventory-ai-#{System.unique_integer([:positive])}.jpg")

    try do
      with {:ok, _path} <- ImageProcessor.preview_jpeg(original, output, @max_edge),
           {:ok, data} <- File.read(output) do
        {:ok, data}
      else
        {:error, reason} -> skip(uuid, "not an image: #{reason_text(reason)}")
      end
    after
      File.rm(original)
      File.rm(output)
    end
  end

  defp skip(uuid, reason) do
    Logger.info("[inventory ai] photo #{uuid} skipped: #{reason}")
    {:error, reason}
  end

  defp reason_text(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp reason_text(reason), do: inspect(reason)
end
