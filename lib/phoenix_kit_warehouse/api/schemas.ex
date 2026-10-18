defmodule PhoenixKitWarehouse.API.Schemas do
  @moduledoc """
  The JSON Schemas (string keys, the draft 2020-12 subset the core validator
  understands) of the five warehouse tools. Every input schema is closed
  (`additionalProperties: false`): an unknown field is a 422, never ignored.
  The descriptions are written for an agent.
  """

  alias PhoenixKitWarehouse.GoodsIssue

  @max_lines 500
  @max_refs 50

  @doc false
  def max_lines, do: @max_lines

  @doc false
  def max_refs, do: @max_refs

  @decimal ~S|A decimal string such as "12" or "0.5" (or a JSON number): 0 to 1000000000, at most 6 decimal places.|

  # --- shared pieces ----------------------------------------------------------

  defp uuid(description),
    do: %{"type" => "string", "minLength" => 36, "maxLength" => 36, "description" => description}

  defp external_ref do
    %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 255,
      "description" =>
        "The number of this document in the outside system. Unique per document type among posted " <>
          "documents: sending the same reference again changes nothing and answers status \"skipped\" " <>
          "with the existing document number; if the request differs from that document, or has a " <>
          "line a first call would refuse, it is refused as validation_failed instead. Always send " <>
          "it when you can."
    }
  end

  defp ref do
    %{
      "type" => "object",
      "description" =>
        "Identifies a product by exactly one of: id (the catalogue item UUID), sku, external_id. " <>
          "It is looked up in the catalogue given by catalogue_id.",
      "properties" => %{
        "id" => uuid("Catalogue item UUID."),
        "sku" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
        "external_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 255}
      },
      "additionalProperties" => false
    }
  end

  defp decimal(description),
    do: %{"type" => ["string", "number"], "description" => description <> " " <> @decimal}

  defp location_id do
    uuid(
      "A warehouse location (see warehouse.list_locations). Defaults to the default warehouse setting; " <>
        "when none is set the call fails and says so."
    )
  end

  defp catalogue_id do
    uuid(
      "The catalogue the refs resolve in (all of them, an id too). Required when the shop has more than " <>
        "one active catalogue: the call is refused and says so otherwise. Without it the only active " <>
        "catalogue is used. A deleted catalogue is refused; an archived one can be read but not written."
    )
  end

  defp line(kind) do
    base = %{
      "ref" => ref(),
      "quantity" => decimal(quantity_description(kind))
    }

    properties =
      if kind == :receipt,
        do:
          Map.put(
            base,
            "unit_value",
            decimal(
              "Optional. The cost of one unit; replaces the stored unit value of the product here."
            )
          ),
        else: base

    %{
      "type" => "object",
      "required" => ["ref", "quantity"],
      "properties" => properties,
      "additionalProperties" => false
    }
  end

  defp quantity_description(:receipt), do: "The quantity received; greater than zero."
  defp quantity_description(:issue), do: "The quantity written off; greater than zero."

  defp quantity_description(:inventory),
    do: "The counted quantity the stock is set to; 0 is allowed."

  defp lines(kind) do
    %{
      "type" => "array",
      "minItems" => 1,
      "maxItems" => @max_lines,
      "items" => line(kind),
      "description" =>
        "One line per product, at most #{@max_lines}. A product may appear on one line only (a second " <>
          "line for it is refused as duplicate_line). The document is atomic: if any line is wrong " <>
          "nothing is posted and every problem is reported."
    }
  end

  defp write_input(kind, extra_properties, required) do
    properties =
      Map.merge(
        %{
          "location_id" => location_id(),
          "catalogue_id" => catalogue_id(),
          "lines" => lines(kind),
          "note" => %{
            "type" => "string",
            "maxLength" => 1000,
            "description" => "A free-text note stored on the document."
          }
        },
        extra_properties
      )

    %{
      "type" => "object",
      "required" => required,
      "properties" => properties,
      "additionalProperties" => false
    }
  end

  # --- inputs -----------------------------------------------------------------

  @doc false
  def list_locations_input,
    do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

  @doc false
  def get_stock_input do
    %{
      "type" => "object",
      "required" => ["refs"],
      "properties" => %{
        "refs" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_refs,
          "items" => ref(),
          "description" => "The products to read, at most #{@max_refs}."
        },
        "location_id" =>
          uuid(
            "Read this warehouse location only. Without it every location holding the product is listed."
          ),
        "catalogue_id" => catalogue_id()
      },
      "additionalProperties" => false
    }
  end

  @doc false
  def receive_stock_input,
    do: write_input(:receipt, %{"external_ref" => external_ref()}, ["lines"])

  @doc false
  def set_stock_input,
    do: write_input(:inventory, %{"external_ref" => external_ref()}, ["lines"])

  @doc false
  def issue_stock_input do
    write_input(
      :issue,
      %{
        "reason" => %{
          "type" => "string",
          "enum" => GoodsIssue.reasons(),
          "description" => "Why the stock leaves: sale, damage, production or other."
        },
        "external_ref" =>
          Map.update!(
            external_ref(),
            "description",
            &(&1 <>
                " Not allowed together with an external source: its ref is the external reference.")
          ),
        "source" => %{
          "type" => "object",
          "required" => ["kind"],
          "properties" => %{
            "kind" => %{"type" => "string", "enum" => ["external", "shop_order"]},
            "ref" => external_ref(),
            "id" => uuid("The order UUID, for kind shop_order.")
          },
          "additionalProperties" => false,
          "description" =>
            ~S|The basis of the write-off. {"kind": "external", "ref": "<document number>"} is stored as | <>
              ~S|the document's external reference (and makes a retry harmless). {"kind": "shop_order", | <>
              ~S|"id": "<order uuid>"} links the write-off to a shop order; it needs the E-commerce module. | <>
              "Send external_ref beside a shop_order source (or without any source) to make a retry harmless too."
        }
      },
      ["reason", "lines"]
    )
  end

  # --- outputs ------------------------------------------------------------------

  @doc false
  def list_locations_output do
    %{
      "type" => "object",
      "properties" => %{
        "locations" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "id" => %{"type" => "string"},
              "name" => %{"type" => "string"},
              "status" => %{"type" => "string", "enum" => ["active", "inactive"]},
              "default" => %{"type" => "boolean"}
            }
          }
        },
        "default_location_id" => %{"type" => ["string", "null"]},
        "setup" => %{
          "type" => "string",
          "enum" => ["ready", "needs_location_type", "needs_locations", "needs_default_location"]
        }
      }
    }
  end

  @doc false
  def get_stock_output do
    %{
      "type" => "object",
      "properties" => %{
        "results" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "ref" => %{"type" => "object"},
              "id" => %{"type" => "string"},
              "sku" => %{"type" => ["string", "null"]},
              "name" => %{"type" => ["string", "null"]},
              "unit" => %{
                "type" => ["string", "null"],
                "description" =>
                  "The unit of the product. Every quantity is in this unit; the warehouse converts nothing."
              },
              "locations" => %{
                "type" => "array",
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "location_id" => %{"type" => "string"},
                    "name" => %{"type" => ["string", "null"]},
                    "quantity" => %{"type" => "string"},
                    "unit_value" => %{"type" => ["string", "null"]}
                  }
                }
              },
              "total" => %{"type" => "string"},
              "error" => %{
                "type" => "object",
                "properties" => %{
                  "code" => %{"type" => "string"},
                  "message" => %{"type" => "string"},
                  "candidates" => %{"type" => "array", "items" => %{"type" => "string"}}
                }
              }
            }
          }
        }
      }
    }
  end

  @doc false
  def write_output do
    %{
      "type" => "object",
      "properties" => %{
        "status" => %{"type" => "string", "enum" => ["posted", "skipped", "unchanged"]},
        "document" => %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string"},
            "type" => %{
              "type" => "string",
              "enum" => ["goods_receipt", "goods_issue", "inventory"]
            },
            "number" => %{"type" => "integer"},
            "external_ref" => %{"type" => ["string", "null"]},
            "location_id" => %{"type" => "string"},
            "posted_at" => %{"type" => ["string", "null"]},
            "reason" => %{"type" => "string"}
          }
        },
        "results" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "ref" => %{"type" => "object"},
              "action" => %{"type" => "string", "enum" => ["updated", "unchanged", "skipped"]},
              "id" => %{"type" => "string"},
              "from" => %{"type" => "string"},
              "to" => %{"type" => "string"}
            }
          }
        },
        "summary" => %{"type" => "object"},
        "effects" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "code" => %{"type" => "string"},
              "message" => %{"type" => "string"}
            }
          }
        }
      }
    }
  end
end
