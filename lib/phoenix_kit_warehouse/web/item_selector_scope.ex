defmodule PhoenixKitWarehouse.Web.ItemSelectorScope do
  @moduledoc """
  Builds the `scope` the catalogue's `ItemSelectorModal` gets from a
  warehouse document form.

  The modal only builds a category tree for a scope that names its
  catalogues: its `do_build_category_tree/3` matches on `:catalogue_uuids`
  (one entry = that catalogue's own root, several = the catalogue-first
  drill) and every other shape falls through to the empty tree. A scope of
  just `%{statuses: ["active"]}` therefore opens the picker with no group
  navigation at all — a flat search box over every item in the system.

  Naming every catalogue restores the hierarchical browse without narrowing
  what a document may contain. The list is resolved fresh each time the
  picker opens, so a newly-added catalogue shows up without a reload.
  """

  alias PhoenixKitCatalogue.Catalogue

  @doc """
  Every non-deleted catalogue, scoped to active items. Call it when the
  picker opens, not in `mount/3` — it is a query, and mount runs twice.
  """
  @spec build() :: %{catalogue_uuids: [String.t()], statuses: [String.t()]}
  def build do
    %{
      catalogue_uuids: Catalogue.list_catalogues() |> Enum.map(& &1.uuid),
      statuses: ["active"]
    }
  end
end
