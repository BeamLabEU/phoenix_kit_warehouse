defmodule PhoenixKitWarehouse.InventoryAI.Response do
  @moduledoc """
  The answer of the photo inventory's model: the strict JSON schema it is
  asked in (`schema/0`) and the check of what came back (`check/2`).

  Nothing the model writes reaches a proposal unchecked. A catalogue number
  that is not in the list the model saw becomes `nil`; alternatives keep
  only numbers from the list; photo numbers only `1..N`; every count is a
  `Decimal` within its range. A value that had to be changed leaves a
  warning (`%{"object_key", "field", "issue"}`) next to the objects, so the
  person sees what was not taken as written. Names, units, catalogues and
  categories are never read from the answer - they come from the catalogue.
  """

  @confidences ~w(high medium low)
  @packages ~w(box pack blister bag bin sheet_stack board_stack roll loose other)

  @max_text 120
  @max_key 60
  @max_alternatives 3

  @fill_default Decimal.new("0.35")
  @fill_max Decimal.new("0.4")
  @zero Decimal.new(0)

  @nullable_number %{"type" => ["number", "null"]}

  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["off_purpose", "nothing_found", "overlap", "objects"],
    "properties" => %{
      "off_purpose" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["flag", "reason"],
        "properties" => %{
          "flag" => %{"type" => "boolean"},
          "reason" => %{"type" => "string"}
        }
      },
      "nothing_found" => %{"type" => "boolean"},
      "overlap" => %{"type" => "string"},
      "objects" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => [
            "object_key",
            "photos",
            "description",
            "catalogue_no",
            "alternatives",
            "match_confidence",
            "package",
            "closed_packages",
            "open_packages",
            "open_fill",
            "units_per_package",
            "loose_units",
            "quantity",
            "count_confidence",
            "basis"
          ],
          "properties" => %{
            "object_key" => %{"type" => "string"},
            "photos" => %{"type" => "array", "items" => %{"type" => "integer"}},
            "description" => %{"type" => "string"},
            "catalogue_no" => %{"type" => ["integer", "null"]},
            "alternatives" => %{"type" => "array", "items" => %{"type" => "integer"}},
            "match_confidence" => %{"type" => "string", "enum" => @confidences},
            "package" => %{"type" => "string", "enum" => @packages},
            "closed_packages" => %{"type" => "number"},
            "open_packages" => %{"type" => "number"},
            "open_fill" => @nullable_number,
            "units_per_package" => @nullable_number,
            "loose_units" => @nullable_number,
            "quantity" => @nullable_number,
            "count_confidence" => %{"type" => "string", "enum" => @confidences},
            "basis" => %{"type" => "string"}
          }
        }
      }
    }
  }

  @typedoc "What `check/2` needs: how many photos were sent, and the catalogue numbers the model saw."
  @type context :: %{photo_count: non_neg_integer(), numbers: MapSet.t(pos_integer())}

  @type checked :: %{
          objects: [map()],
          nothing_found: boolean(),
          overlap: String.t(),
          warnings: [map()]
        }

  @doc "The strict JSON schema of the answer (spec §6.3)."
  @spec schema() :: map()
  def schema, do: @schema

  @doc "The schema's name in the request."
  @spec schema_name() :: String.t()
  def schema_name, do: "inventory_count"

  @doc """
  Checks the parsed answer (spec §6.4).

  `{:ok, checked}` - the objects as maps with string keys, every count a
  `Decimal`; `nothing_found` is `true` (and the objects empty) when the
  model said so or found none. `{:off_purpose, reason}` when the model
  flagged the photos as not about a warehouse. `{:error, :not_an_object}`
  for anything that is not a JSON object.
  """
  @spec check(term(), context()) ::
          {:ok, checked()} | {:off_purpose, String.t()} | {:error, :not_an_object}
  def check(answer, context) when is_map(answer) do
    case answer["off_purpose"] do
      %{"flag" => true} = off_purpose -> {:off_purpose, text(off_purpose["reason"], @max_text)}
      _ -> {:ok, check_objects(answer, context)}
    end
  end

  def check(_answer, _context), do: {:error, :not_an_object}

  @doc """
  Whether a failed call was an answer cut off inside its JSON: the model
  began the object (or a json block) and ran out of room. The call is paid
  all the same, and a smaller batch is the way out.
  """
  @spec truncated?(term()) :: boolean()
  def truncated?({:no_json_in_response, text}) when is_binary(text) do
    trimmed = String.trim_leading(text)
    String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "```")
  end

  def truncated?(_reason), do: false

  # --- objects ---------------------------------------------------------------------

  defp check_objects(answer, context) do
    raw = if is_list(answer["objects"]), do: answer["objects"], else: []
    base = %{overlap: text(answer["overlap"], 1000), warnings: []}

    if answer["nothing_found"] == true do
      warnings = if raw == [], do: [], else: [warning(nil, "objects", "ignored_nothing_found")]
      Map.merge(base, %{objects: [], nothing_found: true, warnings: warnings})
    else
      {objects, warnings} =
        raw
        |> Enum.with_index(1)
        |> Enum.reduce({[], []}, fn {entry, index}, {objects, warnings} ->
          case check_object(entry, index, context) do
            {:ok, object, object_warnings} ->
              {[object | objects], warnings ++ object_warnings}

            :skip ->
              {objects,
               warnings ++ [warning(Integer.to_string(index), "objects", "not_an_object")]}
          end
        end)

      objects = Enum.reverse(objects)
      Map.merge(base, %{objects: objects, nothing_found: objects == [], warnings: warnings})
    end
  end

  defp check_object(entry, index, context) when is_map(entry) do
    key =
      case text(entry["object_key"], @max_key) do
        "" -> Integer.to_string(index)
        key -> key
      end

    {catalogue_no, w1} = catalogue_no(entry["catalogue_no"], context.numbers, key)
    {closed, w2} = package_count(entry["closed_packages"], key, "closed_packages")
    {open, w3} = package_count(entry["open_packages"], key, "open_packages")
    {fill, w4} = open_fill(entry["open_fill"], key)
    {per_package, w5} = positive_or_nil(entry["units_per_package"], key, "units_per_package")
    {loose, w6} = non_negative_or_nil(entry["loose_units"], key, "loose_units")
    {quantity, w7} = non_negative_or_nil(entry["quantity"], key, "quantity")

    object = %{
      "object_key" => key,
      "photos" => photos(entry["photos"], context.photo_count),
      "description" => text(entry["description"], @max_text),
      "catalogue_no" => catalogue_no,
      "alternatives" => alternatives(entry["alternatives"], catalogue_no, context.numbers),
      "match_confidence" => enum(entry["match_confidence"], @confidences, "low"),
      "package" => enum(entry["package"], @packages, "other"),
      "closed_packages" => closed,
      "open_packages" => open,
      "open_fill" => fill,
      "units_per_package" => per_package,
      "loose_units" => loose,
      "quantity" => quantity,
      "count_confidence" => enum(entry["count_confidence"], @confidences, "low"),
      "basis" => text(entry["basis"], @max_text)
    }

    {:ok, object, Enum.concat([w1, w2, w3, w4, w5, w6, w7])}
  end

  defp check_object(_entry, _index, _context), do: :skip

  defp catalogue_no(nil, _numbers, _key), do: {nil, []}

  defp catalogue_no(value, numbers, key) do
    case whole(value) do
      {:ok, number} ->
        if MapSet.member?(numbers, number),
          do: {number, []},
          else: {nil, [warning(key, "catalogue_no", "not_in_catalogue")]}

      :error ->
        {nil, [warning(key, "catalogue_no", "not_in_catalogue")]}
    end
  end

  defp alternatives(values, chosen, numbers) when is_list(values) do
    values
    |> Enum.flat_map(fn value ->
      case whole(value) do
        {:ok, number} -> [number]
        :error -> []
      end
    end)
    |> Enum.filter(&(MapSet.member?(numbers, &1) and &1 != chosen))
    |> Enum.uniq()
    |> Enum.take(@max_alternatives)
  end

  defp alternatives(_values, _chosen, _numbers), do: []

  defp photos(values, count) when is_list(values) do
    values
    |> Enum.filter(&(is_integer(&1) and &1 >= 1 and &1 <= count))
    |> Enum.uniq()
  end

  defp photos(_values, _count), do: []

  # Whole and >= 0; a fraction goes down, a negative becomes 0 and is said.
  defp package_count(value, key, field) do
    case number(value) do
      {:ok, decimal} ->
        if Decimal.negative?(decimal),
          do: {@zero, [warning(key, field, "negative")]},
          else: {Decimal.round(decimal, 0, :floor), []}

      :error ->
        {@zero, [warning(key, field, "not_a_number")]}
    end
  end

  defp open_fill(nil, _key), do: {@fill_default, []}

  defp open_fill(value, key) do
    case number(value) do
      {:ok, decimal} ->
        cond do
          Decimal.negative?(decimal) ->
            {@zero, [warning(key, "open_fill", "out_of_range")]}

          Decimal.gt?(decimal, @fill_max) ->
            {@fill_max, [warning(key, "open_fill", "out_of_range")]}

          true ->
            {decimal, []}
        end

      :error ->
        {@fill_default, [warning(key, "open_fill", "not_a_number")]}
    end
  end

  defp positive_or_nil(nil, _key, _field), do: {nil, []}

  defp positive_or_nil(value, key, field) do
    case number(value) do
      {:ok, decimal} ->
        if Decimal.gt?(decimal, 0),
          do: {decimal, []},
          else: {nil, [warning(key, field, "out_of_range")]}

      :error ->
        {nil, [warning(key, field, "not_a_number")]}
    end
  end

  # A bad value is `nil` (to be typed by a person), never 0.
  defp non_negative_or_nil(nil, _key, _field), do: {nil, []}

  defp non_negative_or_nil(value, key, field) do
    case number(value) do
      {:ok, decimal} ->
        if Decimal.negative?(decimal),
          do: {nil, [warning(key, field, "negative")]},
          else: {decimal, []}

      :error ->
        {nil, [warning(key, field, "not_a_number")]}
    end
  end

  # A JSON number as a Decimal; a float by its shortest text.
  defp number(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp number(value) when is_float(value), do: {:ok, Decimal.from_float(value)}
  defp number(_value), do: :error

  defp whole(value) when is_integer(value), do: {:ok, value}

  defp whole(value) when is_float(value) do
    if value == Float.round(value), do: {:ok, trunc(value)}, else: :error
  end

  defp whole(_value), do: :error

  defp enum(value, allowed, default), do: if(value in allowed, do: value, else: default)

  defp text(value, max) when is_binary(value), do: value |> String.trim() |> String.slice(0, max)
  defp text(_value, _max), do: ""

  defp warning(key, field, issue), do: %{"object_key" => key, "field" => field, "issue" => issue}
end
