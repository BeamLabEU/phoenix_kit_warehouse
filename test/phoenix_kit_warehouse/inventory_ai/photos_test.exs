defmodule PhoenixKitWarehouse.InventoryAI.PhotosTest do
  # The photos of a run, made again from the originals before the call
  # (spec §10.1): JPEG, at most 2000 px on the long side, turned by EXIF,
  # HEIC read; a photo that cannot be read is skipped and the numbering
  # follows; the temporary files are gone afterwards. The originals come
  # through `:retrieve` - a copy in a temporary file, the way
  # `Storage.retrieve_file/1` hands them over.
  use ExUnit.Case, async: true

  # The photos are made with ImageMagick.
  @moduletag :imagemagick

  alias PhoenixKitWarehouse.InventoryAI.Photos

  @fixtures Path.expand("../../fixtures/inventory_ai", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "pkw-photos-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # A temporary copy per call, recorded so the test can see it is removed.
  defp retriever(dir, originals) do
    test = self()

    fn uuid ->
      case Map.fetch(originals, uuid) do
        {:ok, source} ->
          copy =
            Path.join(dir, "copy-#{System.unique_integer([:positive])}#{Path.extname(source)}")

          File.cp!(source, copy)
          send(test, {:copied, copy})
          {:ok, copy, %{uuid: uuid}}

        :error ->
          {:error, "File not found"}
      end
    end
  end

  defp image!(dir, name, args) do
    path = Path.join(dir, name)
    {_, 0} = System.cmd("convert", args ++ [path], stderr_to_stdout: true)
    path
  end

  # A JPEG with an APP1 EXIF segment that says "rotate 90° clockwise" (6).
  defp exif_rotated!(dir) do
    plain = image!(dir, "plain.jpg", ["-size", "40x20", "xc:red"])
    <<0xFF, 0xD8, rest::binary>> = File.read!(plain)

    tiff =
      <<"II*", 0, 8::little-32, 1::little-16, 0x0112::little-16, 3::little-16, 1::little-32,
        6::little-16, 0::little-16, 0::little-32>>

    payload = "Exif" <> <<0, 0>> <> tiff
    path = Path.join(dir, "rotated.jpg")
    File.write!(path, <<0xFF, 0xD8, 0xFF, 0xE1, byte_size(payload) + 2::16>> <> payload <> rest)
    path
  end

  defp dimensions!(dir, data) do
    path = Path.join(dir, "out-#{System.unique_integer([:positive])}.jpg")
    File.write!(path, data)
    {out, 0} = System.cmd("identify", ["-format", "%m %w %h", path])
    [format, w, h] = String.split(out)
    {format, String.to_integer(w), String.to_integer(h)}
  end

  # Only an ImageMagick built with HEIC support reads the fixture.
  @tag :heic
  test "a HEIC photo becomes a JPEG", %{dir: dir} do
    retrieve = retriever(dir, %{"heic" => Path.join(@fixtures, "shelf.heic")})

    assert {:ok, %{images: [image], file_uuids: ["heic"], skipped: []}} =
             Photos.prepare(["heic"], retrieve: retrieve)

    assert image.content_type == "image/jpeg"
    assert dimensions!(dir, image.data) == {"JPEG", 64, 48}
  end

  test "the long side is brought down to 2000 px, a small photo is not enlarged", %{dir: dir} do
    big = image!(dir, "big.png", ["-size", "3000x1200", "xc:blue"])
    small = image!(dir, "small.png", ["-size", "300x200", "xc:green"])
    retrieve = retriever(dir, %{"big" => big, "small" => small})

    {:ok, %{images: [b, s]}} = Photos.prepare(["big", "small"], retrieve: retrieve)

    assert dimensions!(dir, b.data) == {"JPEG", 2000, 800}
    assert dimensions!(dir, s.data) == {"JPEG", 300, 200}
  end

  test "the EXIF orientation is applied", %{dir: dir} do
    retrieve = retriever(dir, %{"rot" => exif_rotated!(dir)})

    {:ok, %{images: [image]}} = Photos.prepare(["rot"], retrieve: retrieve)

    assert dimensions!(dir, image.data) == {"JPEG", 20, 40}
  end

  test "a photo that cannot be read is skipped, the numbering follows the rest", %{dir: dir} do
    broken = Path.join(dir, "broken.jpg")
    File.write!(broken, "this is not an image")
    good = image!(dir, "good.png", ["-size", "30x30", "xc:white"])
    retrieve = retriever(dir, %{"broken" => broken, "good" => good})

    assert {:ok, %{images: [_], file_uuids: ["good"], skipped: skipped}} =
             Photos.prepare(["broken", "missing", "good"], retrieve: retrieve)

    assert Enum.map(skipped, & &1["file_uuid"]) == ["broken", "missing"]
    assert Enum.all?(skipped, &is_binary(&1["reason"]))
  end

  test "no photo left is an error", %{dir: dir} do
    assert Photos.prepare(["missing"], retrieve: retriever(dir, %{})) == {:error, :no_photos}
    assert Photos.prepare([], retrieve: retriever(dir, %{})) == {:error, :no_photos}
  end

  test "a batch over the byte limit is refused before any call", %{dir: dir} do
    a = image!(dir, "a.png", ["-size", "50x50", "plasma:"])
    retrieve = retriever(dir, %{"a" => a})

    assert {:error, {:too_large, bytes, 100}} =
             Photos.prepare(["a"], retrieve: retrieve, max_total_bytes: 100)

    assert bytes > 100
  end

  test "the limit is 80 MB by default" do
    assert Photos.max_total_bytes() == 80_000_000
  end

  test "the temporary files are removed, read or not", %{dir: dir} do
    broken = Path.join(dir, "broken.jpg")
    File.write!(broken, "nope")
    good = image!(dir, "good.png", ["-size", "30x30", "xc:white"])

    tmp_before =
      File.ls!(System.tmp_dir!()) |> Enum.filter(&String.starts_with?(&1, "pkw-inventory-ai-"))

    {:ok, _} =
      Photos.prepare(["broken", "good"],
        retrieve: retriever(dir, %{"broken" => broken, "good" => good})
      )

    assert_received {:copied, copy_1}
    assert_received {:copied, copy_2}
    refute File.exists?(copy_1)
    refute File.exists?(copy_2)

    tmp_after =
      File.ls!(System.tmp_dir!()) |> Enum.filter(&String.starts_with?(&1, "pkw-inventory-ai-"))

    assert tmp_after -- tmp_before == []
  end
end
