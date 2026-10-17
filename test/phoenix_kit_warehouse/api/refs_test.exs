defmodule PhoenixKitWarehouse.API.RefsTest do
  @moduledoc """
  `Refs`: a product ref resolves to a live catalogue item or to a row error;
  it never reaches the stock table as a phantom UUID. And the `catalogue_id`
  rule: required when more than one catalogue is active.
  """
  use PhoenixKitWarehouse.DataCase, async: false

  import PhoenixKitWarehouse.Test.ApiFixtures

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitWarehouse.API.Refs

  setup do
    catalogue = shop_catalogue!()
    %{catalogue: catalogue, item: item!(catalogue)}
  end

  describe "an id ref" do
    test "resolves to the item, with what the admin pages print on a line", %{item: item} do
      assert [{:ok, resolved}] = Refs.resolve([%{"id" => item.uuid}])

      assert resolved == %{
               uuid: item.uuid,
               sku: item.sku,
               name: item.name,
               unit: item.unit,
               catalogue_uuid: item.catalogue_uuid
             }
    end

    test "an upper-case UUID resolves to the canonical one", %{item: item} do
      assert [{:ok, %{uuid: uuid}}] = Refs.resolve([%{"id" => String.upcase(item.uuid)}])
      assert uuid == item.uuid
    end

    test "an unknown UUID is a not_found row error" do
      assert [{:error, %{code: "not_found", message: message}}] =
               Refs.resolve([%{"id" => Ecto.UUID.generate()}])

      assert message =~ "No product"
    end

    test "a trashed item is a not_found row error", %{item: item} do
      {:ok, _} = Catalogue.trash_item(item)
      assert [{:error, %{code: "not_found"}}] = Refs.resolve([%{"id" => item.uuid}])
    end

    test "an item of another catalogue is not found when a catalogue is given", %{item: item} do
      other = catalogue!()

      assert [{:error, %{code: "not_found"}}] =
               Refs.resolve([%{"id" => item.uuid}], catalogue_uuid: other.uuid)

      assert [{:ok, _}] =
               Refs.resolve([%{"id" => item.uuid}], catalogue_uuid: item.catalogue_uuid)
    end

    test "an item of a deleted catalogue is not found, for a read and for a write", %{
      catalogue: catalogue,
      item: item
    } do
      # Only the catalogue row changes: `Catalogue.trash_catalogue/1` would trash the items too.
      set_catalogue_status!(catalogue, "deleted")

      for write <- [false, true] do
        assert [{:error, %{code: "not_found"}}] =
                 Refs.resolve([%{"id" => item.uuid}], write: write)
      end
    end

    test "an item of an archived catalogue can be read but not written", %{
      catalogue: catalogue,
      item: item
    } do
      set_catalogue_status!(catalogue, "archived")

      assert [{:ok, %{uuid: uuid}}] = Refs.resolve([%{"id" => item.uuid}])
      assert uuid == item.uuid

      assert [{:error, %{code: "not_found", message: message}}] =
               Refs.resolve([%{"id" => item.uuid}], write: true)

      assert message =~ "archived"
    end
  end

  describe "shapes that are not a ref" do
    test "each is a validation_failed row error, none raises" do
      bad = [
        %{"id" => "nope"},
        # 16 bytes: `Ecto.UUID.cast/1` alone would take it as a raw UUID
        %{"id" => "0123456789abcdef"},
        %{"id" => 5},
        %{},
        %{"id" => Ecto.UUID.generate(), "sku" => "X"},
        %{"sku" => "   "},
        %{"sku" => String.duplicate("a", 256)},
        %{"external_id" => ""},
        %{"other" => "x"},
        "text",
        nil,
        5,
        ["id"]
      ]

      for ref <- bad do
        assert [{:error, %{code: "validation_failed", message: message}}] = Refs.resolve([ref]),
               inspect(ref)

        assert is_binary(message) and message != ""
      end
    end
  end

  describe "the list" do
    test "keeps the order and the length of the input, duplicates included", %{
      catalogue: catalogue,
      item: item
    } do
      other = item!(catalogue)

      result =
        Refs.resolve([
          %{"id" => other.uuid},
          %{"id" => Ecto.UUID.generate()},
          %{"id" => item.uuid},
          %{"id" => other.uuid}
        ])

      assert [
               {:ok, %{uuid: first}},
               {:error, %{code: "not_found"}},
               {:ok, %{uuid: second}},
               {:ok, %{uuid: third}}
             ] = result

      assert {first, second, third} == {other.uuid, item.uuid, other.uuid}
    end

    test "an empty list is an empty list" do
      assert Refs.resolve([]) == []
    end

    test "a ref that is only an id never writes to the stock table", %{item: item} do
      before = Repo.aggregate(PhoenixKitWarehouse.Stock, :count)
      Refs.resolve([%{"id" => item.uuid}, %{"id" => Ecto.UUID.generate()}])
      assert Repo.aggregate(PhoenixKitWarehouse.Stock, :count) == before
    end
  end

  describe "sku and external_id refs" do
    if Code.ensure_loaded?(PhoenixKitCatalogue.API) and
         function_exported?(PhoenixKitCatalogue.API, :resolve_refs, 2) do
      test "go through the catalogue resolver", %{
        catalogue: catalogue,
        item: item
      } do
        assert [{:ok, %{uuid: uuid}}] =
                 Refs.resolve([%{"sku" => item.sku}], catalogue_uuid: catalogue.uuid)

        assert uuid == item.uuid

        assert [{:error, %{code: "not_found"}}] =
                 Refs.resolve([%{"sku" => "NO-SUCH-SKU"}], catalogue_uuid: catalogue.uuid)
      end

      test "an external_id ref resolves through the resolver too", %{catalogue: catalogue} do
        item = item!(catalogue, %{data: %{"api" => %{"external_id" => "EXT-7"}}})

        assert [{:ok, %{uuid: uuid}}] =
                 Refs.resolve([%{"external_id" => "EXT-7"}], catalogue_uuid: catalogue.uuid)

        assert uuid == item.uuid
      end

      test "two items with one sku are an ambiguous_ref with both ids", %{catalogue: catalogue} do
        a = item!(catalogue, %{sku: "TWIN-1"})
        b = item!(catalogue, %{sku: "TWIN-1"})

        assert [{:error, %{code: "ambiguous_ref", candidates: candidates}}] =
                 Refs.resolve([%{"sku" => "TWIN-1"}], catalogue_uuid: catalogue.uuid)

        assert Enum.sort(candidates) == Enum.sort([a.uuid, b.uuid])
      end

      test "a sku of another catalogue is not found when a catalogue is given", %{item: item} do
        other = catalogue!()

        assert [{:error, %{code: "not_found"}}] =
                 Refs.resolve([%{"sku" => item.sku}], catalogue_uuid: other.uuid)
      end

      test "a sku or external_id of an item in a deleted catalogue is not found, read or write",
           %{catalogue: catalogue} do
        item = item!(catalogue, %{data: %{"api" => %{"external_id" => "EXT-DEL"}}})
        set_catalogue_status!(catalogue, "deleted")

        for write <- [false, true],
            ref <- [%{"sku" => item.sku}, %{"external_id" => "EXT-DEL"}] do
          assert [{:error, %{code: "not_found"}}] = Refs.resolve([ref], write: write),
                 inspect({ref, write})
        end
      end

      test "a sku or external_id of an item in an archived catalogue is read, not written",
           %{catalogue: catalogue} do
        item = item!(catalogue, %{data: %{"api" => %{"external_id" => "EXT-ARC"}}})
        set_catalogue_status!(catalogue, "archived")

        for ref <- [%{"sku" => item.sku}, %{"external_id" => "EXT-ARC"}] do
          assert [{:ok, %{uuid: uuid}}] = Refs.resolve([ref]), inspect(ref)
          assert uuid == item.uuid

          assert [{:error, %{code: "not_found", message: message}}] =
                   Refs.resolve([ref], write: true),
                 inspect(ref)

          assert message =~ "archived"
        end
      end

      test "a trashed item found by sku is not found", %{catalogue: catalogue} do
        item = item!(catalogue, %{data: %{"api" => %{"external_id" => "EXT-TRASH"}}})
        {:ok, _} = Catalogue.trash_item(item)

        for ref <- [%{"sku" => item.sku}, %{"external_id" => "EXT-TRASH"}] do
          assert [{:error, %{code: "not_found"}}] = Refs.resolve([ref]), inspect(ref)
        end
      end

      test "a NUL byte in a sku or external_id is a row error, not a crash" do
        for ref <- [%{"sku" => "A" <> <<0>> <> "B"}, %{"external_id" => "A" <> <<0>> <> "B"}] do
          assert [{:error, %{code: code}}] = Refs.resolve([ref]), inspect(ref)
          assert code in ["not_found", "validation_failed"]
        end
      end
    else
      test "answer a row error that says the catalogue lacks the resolver", %{item: item} do
        assert [{:error, %{code: "validation_failed", message: message}}] =
                 Refs.resolve([%{"sku" => item.sku}])

        assert message =~ "sku and external_id"
        assert message =~ "use id"
      end
    end
  end

  describe "normalize_external/1, the one place that knows the resolver's answers" do
    test "maps every answer of the catalogue resolver" do
      uuid = Ecto.UUID.generate()

      assert Refs.normalize_external({:ok, %{uuid: uuid}}) == {:ok, uuid}
      assert {:error, %{code: "not_found"}} = Refs.normalize_external({:error, :not_found})

      assert {:error, %{code: "validation_failed"}} =
               Refs.normalize_external({:error, :invalid_ref})

      assert {:error, %{code: "ambiguous_ref", candidates: [^uuid]}} =
               Refs.normalize_external({:error, {:ambiguous_ref, [uuid]}})
    end

    test "an answer it does not know is a validation_failed row error, not a crash" do
      assert {:error, %{code: "validation_failed"}} = Refs.normalize_external(:surprise)
      assert {:error, %{code: "validation_failed"}} = Refs.normalize_external({:error, :new})
    end
  end

  describe "catalogue_scope/2 (required when more than one catalogue is active)" do
    test "nil is the only active catalogue", %{catalogue: catalogue} do
      assert Refs.catalogue_scope(nil) == {:ok, catalogue.uuid}
    end

    test "nil with two active catalogues is refused and says catalogue_id is required" do
      _second = catalogue!()

      assert {:error, %{path: "catalogue_id", code: "validation_failed", message: message}} =
               Refs.catalogue_scope(nil)

      assert message =~ "catalogue_id"
    end

    test "nil with two active catalogues lists the catalogues to choose from", %{
      catalogue: catalogue
    } do
      second = catalogue!()

      assert {:error, %{allowed: allowed}} = Refs.catalogue_scope(nil)
      assert Enum.sort(allowed) == Enum.sort([catalogue.uuid, second.uuid])
    end

    test "nil with no active catalogue is refused" do
      archive_all_catalogues!()

      assert {:error, %{path: "catalogue_id", code: "validation_failed"}} =
               Refs.catalogue_scope(nil)
    end

    test "an existing active catalogue is returned canonical, also with two active ones", %{
      catalogue: catalogue
    } do
      _second = catalogue!()
      assert Refs.catalogue_scope(String.upcase(catalogue.uuid)) == {:ok, catalogue.uuid}
    end

    test "an unknown, malformed or non-string value is a validation_failed at catalogue_id" do
      for bad <- [Ecto.UUID.generate(), "nope", "0123456789abcdef", 5, %{}] do
        assert {:error, %{path: "catalogue_id", code: "validation_failed", message: message}} =
                 Refs.catalogue_scope(bad)

        assert is_binary(message)
      end
    end

    test "the 16 raw bytes of a catalogue's UUID are not that catalogue", %{catalogue: catalogue} do
      raw = Ecto.UUID.dump!(catalogue.uuid)
      assert byte_size(raw) == 16

      for mode <- [:read, :write] do
        assert {:error, %{path: "catalogue_id", code: "validation_failed"}} =
                 Refs.catalogue_scope(raw, mode)
      end
    end

    test "a deleted catalogue is refused, for a read and for a write", %{catalogue: catalogue} do
      set_catalogue_status!(catalogue, "deleted")

      for mode <- [:read, :write] do
        assert {:error, %{path: "catalogue_id", code: "validation_failed"}} =
                 Refs.catalogue_scope(catalogue.uuid, mode)
      end
    end

    test "an archived catalogue can be read but not written", %{catalogue: catalogue} do
      set_catalogue_status!(catalogue, "archived")

      assert Refs.catalogue_scope(catalogue.uuid, :read) == {:ok, catalogue.uuid}

      assert {:error, %{path: "catalogue_id", message: message}} =
               Refs.catalogue_scope(catalogue.uuid, :write)

      assert message =~ "archived"
    end
  end

  test "error_json/1 renders the code, the message and the candidates only when present" do
    assert Refs.error_json(%{code: "not_found", message: "m"}) ==
             %{"code" => "not_found", "message" => "m"}

    assert Refs.error_json(%{code: "ambiguous_ref", message: "m", candidates: ["a"]}) ==
             %{"code" => "ambiguous_ref", "message" => "m", "candidates" => ["a"]}
  end
end
