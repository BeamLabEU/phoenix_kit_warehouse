defmodule PhoenixKitWarehouse.Web.UserNamesTest do
  use ExUnit.Case, async: true

  alias PhoenixKitWarehouse.Web.UserNames

  describe "label/2" do
    test "renders an unset field as an em dash" do
      assert UserNames.label(%{}, nil) == "—"
    end

    test "returns the resolved name when the uuid is known" do
      names = %{"019d0000-0000-7000-8000-000000000000" => "Ada Lovelace"}
      assert UserNames.label(names, "019d0000-0000-7000-8000-000000000000") == "Ada Lovelace"
    end

    test "falls back to a short uuid stub for an unknown user" do
      # A deleted account or an imported document still says "somebody".
      assert UserNames.label(%{}, "019d0000-0000-7000-8000-000000000000") == "019d0000…"
    end
  end

  describe "resolve/2" do
    test "an empty page needs no query and resolves to an empty map" do
      assert UserNames.resolve([]) == %{}
    end

    test "documents with no user fields set resolve to an empty map" do
      assert UserNames.resolve([%{created_by_uuid: nil, performed_by_uuid: nil}]) == %{}
    end
  end
end
