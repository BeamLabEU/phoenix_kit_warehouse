defmodule PhoenixKitWarehouse.Web.Components.CommentsPanel do
  @moduledoc """
  Presentation helper for warehouse document comment threads. `panel/1`
  embeds the ready-made `PhoenixKitComments.Web.CommentsComponent`.

  Consolidates what were 5 near-identical files in Andi
  (`AndiWeb.Components.{InternalOrder,GoodsIssue,GoodsReceipt,SupplierOrder,
  Inventory}Comments`, under `lib/andi_web/components/` — distinct from the
  5 *context* wrapper modules of the same base names that
  `PhoenixKitWarehouse.Comments` already consolidates) into one module
  parameterized by `kind`, mirroring `PhoenixKitWarehouse.Comments`' own
  `kind :: :goods_issue | :goods_receipt | :internal_order | :supplier_order
  | :inventory` parameterization.

  Callers guard visibility with `PhoenixKitWarehouse.Comments.available?/0`.
  """
  use Phoenix.Component

  alias PhoenixKitWarehouse.Comments

  @doc """
  Embedded comments thread for a warehouse document.

  Assigns:
    * `:kind` — `:goods_issue | :goods_receipt | :internal_order |
      :supplier_order | :inventory` (required)
    * `:resource_uuid` — the document's uuid, used as `resource_uuid`
      (required)
    * `:current_user` — current user struct (or nil) (required)
    * `:id` — optional DOM id; defaults to `comments-<kind>-<uuid>`
    * `:title` — optional heading; defaults to `""`
    * `:read_only` — when true, render without composer or chrome
  """
  attr(:kind, :atom,
    required: true,
    values: [:goods_issue, :goods_receipt, :internal_order, :supplier_order, :inventory]
  )

  attr(:resource_uuid, :string, required: true)
  attr(:current_user, :any, required: true)
  attr(:id, :string, default: nil)
  attr(:title, :string, default: "")
  attr(:read_only, :boolean, default: false)

  def panel(assigns) do
    assigns =
      assigns
      |> assign(:id, assigns.id || "comments-#{assigns.kind}-#{assigns.resource_uuid}")
      |> assign(:composer_position, if(assigns.read_only, do: nil, else: :top))
      |> assign(:show_chrome, not assigns.read_only)

    ~H"""
    <.live_component
      module={PhoenixKitComments.Web.CommentsComponent}
      id={@id}
      resource_type={Comments.resource_type(@kind)}
      resource_uuid={@resource_uuid}
      current_user={@current_user}
      title={@title}
      show_title={@show_chrome}
      show_likes={@show_chrome}
      composer_position={@composer_position}
    />
    """
  end
end
