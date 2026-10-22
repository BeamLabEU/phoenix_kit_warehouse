defmodule PhoenixKitWarehouse.InventoryAIRun do
  @moduledoc """
  One run of the photo inventory: the photos of one place, sent to the AI
  once, and what came back (chain version 3,
  `phoenix_kit_warehouse_inventory_ai_runs`).

  Statuses: `running` (the task is asking the AI), then `proposed` (a
  checked proposal waits for a person) or `error`; a proposal ends
  `applied` or `discarded`. A document has at most one `running` run (a
  partial unique index). An answer that arrives after the run was closed
  goes to `late_result` and does not change the status.

  `catalogue_map` maps the line numbers the model saw (`"1"`, `"2"`, ...) to
  the catalogue items. `result` holds the scope of the request and, once
  answered, the checked answer and the rows of the proposal. `decisions`
  holds what was applied (or why the run was closed). The users are kept as
  uuids without a foreign key, like the document's `created_by_uuid`.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type Ecto.UUID

  @statuses ~w(running proposed error applied discarded)

  # Single shape authority for chain version 3 of `PhoenixKitWarehouse.Migrations`.
  @column_widths %{place_label: 200, status: 20, model: 255}

  schema "phoenix_kit_warehouse_inventory_ai_runs" do
    field(:inventory_uuid, Ecto.UUID)
    field(:location_uuid, Ecto.UUID)
    field(:place_label, :string)
    field(:photo_file_uuids, {:array, Ecto.UUID}, default: [])
    field(:status, :string, default: "running")
    field(:endpoint_uuid, Ecto.UUID)
    field(:model, :string)
    field(:prompt_uuid, Ecto.UUID)
    field(:ai_request_uuid, Ecto.UUID)
    field(:catalogue_map, :map, default: %{})
    field(:result, :map)
    field(:decisions, :map)
    field(:error, :string)
    field(:created_by_uuid, Ecto.UUID)
    field(:applied_by_uuid, Ecto.UUID)
    field(:late_result, :map)
    field(:applied_at, :utc_datetime)
    # Set by `InventoryAI.list_runs/1`, which leaves `late_result` out.
    field(:late_answer?, :boolean, virtual: true, default: false)

    timestamps(type: :utc_datetime)
  end

  @doc "The `character varying(N)` widths chain version 3 builds the table from."
  @spec column_widths() :: %{atom() => pos_integer()}
  def column_widths, do: @column_widths

  @doc "Every status a run can be in."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses
end
