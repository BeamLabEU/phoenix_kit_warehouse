defmodule PhoenixKitWarehouse.InventoryAI.Prompt do
  @moduledoc """
  The prompt the photo inventory asks the model with.

  The prompt lives in PhoenixKit AI's prompts, so a person edits it in
  `/admin/ai/prompts`. Its uuid is kept in the setting
  `warehouse_inventory_ai_prompt_uuid`:

    * the prompt is looked up **by that uuid**, never by name or slug (a
      rename changes both);
    * an empty setting, a uuid that is not one, or a uuid of a prompt that is
      gone: the prompt is made from `template/0` and the setting follows it;
    * a prompt that exists is brought up to the current template only while
      it is this module's own (`metadata.managed_by`
      `"phoenix_kit_warehouse"`), switched on and still holds the text of a
      template shipped before (`previous_template_shas/0`): under a row lock,
      so that a second tab writes nothing and a person's edit is never
      overwritten, through `PhoenixKitAI.update_prompt/3`, which journals it.
      A prompt a person edited, or one they chose of their own, is never
      rewritten;
    * a switched-off prompt is an error, not a reason to make another.

  Two tabs making it at once: the second insert breaks the unique name. It
  then takes the prompt the first one made (found by `name/0` and
  `metadata.managed_by`); a prompt of that name that is not this module's is
  an error.

  The request the prompt is sent with (built by the caller) has the
  numbered photos, a `CATALOGUE` block - one line per item,
  `No|name|sku|unit|catalogue > category path`, a ★ before the number of an
  item held on the warehouse - and a `LANGUAGE` line; the template refers to
  all three.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.Settings

  @setting_key "warehouse_inventory_ai_prompt_uuid"
  @name "Warehouse inventory count"
  @managed_by "phoenix_kit_warehouse"

  # The rules the model works by. English whatever the interface language:
  # the model writes `description` and `basis` in the language `LANGUAGE`
  # names. No `{{` anywhere: the prompt module reads it as a variable.
  @template """
  You count stock on photos for a warehouse. The request has the photos, numbered 1..N in the order given, then a `CATALOGUE` block and a `LANGUAGE` line (for example et, ru, uk or en). The `CATALOGUE` has one line per catalogue item: `No|name|sku|unit|catalogue > category path`. A ★ in front of the number means the item is held on this warehouse.

  The photos are taken in one place and may overlap. One entry is one kind of item in one place: give it a short `object_key` and list in `photos` every photo it is visible on. Never count the same thing twice. Say in `overlap` which photos show the same things. A bag, a box or a blister that holds several kinds of items (dowels, a hook and screws) gives one entry per kind, each with its own `object_key` and the photos of that bag.

  Choose the item of every entry:
  - `catalogue_no` is the number of a `CATALOGUE` line and nothing else. If no line fits, or the variant you need (a size, a colour) cannot be seen, answer `null` and give up to 3 numbers in `alternatives`. `null` is better than a wrong number: a person will choose.
  - Lines with ★ are held on this warehouse. Use that to choose between similar variants, never as a reason to see something that is not on the photo.
  - Give `match_confidence` honestly.

  Count only what is visible:
  - An entry whose `CATALOGUE` line has the unit `pack` is counted in packs: every bag or pack of it goes to `closed_packages` (an opened one to `open_packages` with `open_fill`), also when its pieces can be seen through it; `units_per_package` and `loose_units` stay `null`.
  - For every other entry, first look whether you can see the items themselves. In a transparent bag, an open box or bin, a blister with clear windows, or a loose pile, count the pieces you see and put them in `loose_units`; `closed_packages` and `open_packages` are then 0. Several packs of one kind are counted as packs (see `units_per_package`). Pieces counted through the plastic are better than a package count. When some pieces hide others, count what you see and set `count_confidence` to `medium` or `low`.
  - Count packages only when their inside cannot be seen (a carton, an opaque bag, a box with a lid) or when there are several packs of one kind. A closed package is full: count it in `closed_packages`. An open package is counted in `open_packages`, and `open_fill` is how full it is - estimate it by its look, honestly, from 0 to 0.4 (almost empty 0.05; half full or more 0.4). Use 0.35 only when the fill cannot be seen at all.
  - `closed_packages` and `open_packages` are whole numbers.
  - `units_per_package` (never for a `pack` line) only when it is printed on the label, or when there are several packs of one kind and you can count every piece in one of them - then `count_confidence` is at most `medium`; otherwise `null`. Then the packs go to `closed_packages`, not the pieces to `loose_units`.
  - The sheets of a stack, the boards of a pile, and a product that is alone in its own box (one product per package) also go to `loose_units`: count the products, not the boxes.
  - `quantity` is only for measured units (`m2`, `running_meter`, `kg`, `litre`, `m3` - the unit code is in the `CATALOGUE` line), in the unit of that line. For items counted in pieces it is `null`; it is never a share of a package.
  - Dense rows of small packages (blister packs on hooks): count the packs in `closed_packages`, with `units_per_package` as above, and set `count_confidence` to `low` when a stack goes deep behind the first one.

  Write `description` and `basis` in the language named in `LANGUAGE`, each at most 120 characters. `basis` says how the count was made.

  `off_purpose.flag` is `true` only when the photos are not about a warehouse at all (documents, a screen, people, a request to do something else); give a short `reason`. List every stock object you see, also when no `CATALOGUE` line fits it (then `catalogue_no` is `null`): a person will choose the item. `nothing_found` is `true` only when no stock objects are visible at all (an empty shelf); then `objects` is empty. That is not `off_purpose`.

  Answer with a JSON object only, in the given schema.
  """

  # The sha256 (`template_sha/1`) of every template shipped before the current
  # one, oldest first. A change of `@template` adds the sha of the text it
  # replaces here, so the prompts still holding it are brought up to date.
  @previous_templates [
    # The first: a see-through bag was one package, a mixed bag one object.
    "b5df51bf350074448dace13205dff7f7edc5a91492d7c87987110fb96f6e9f3e"
  ]

  @doc "The settings key holding the prompt's uuid."
  @spec setting_key() :: String.t()
  def setting_key, do: @setting_key

  @doc "The name the prompt is made under."
  @spec name() :: String.t()
  def name, do: @name

  @doc "The text a new prompt is made with."
  @spec template() :: String.t()
  def template, do: String.trim(@template)

  @doc "The sha256 (hex) of a prompt text, trimmed: what a template is recognised by."
  @spec template_sha(String.t()) :: String.t()
  def template_sha(text) when is_binary(text),
    do: :sha256 |> :crypto.hash(String.trim(text)) |> Base.encode16(case: :lower)

  @doc false
  @spec previous_template_shas() :: [String.t()]
  def previous_template_shas, do: @previous_templates

  @doc """
  The prompt to ask with: the one the setting names, made when there is none,
  and brought up to the current template while it holds one shipped before.
  `{:error, {:prompt_error, :disabled}}` for a switched-off one;
  `{:error, {:prompt_error, :name_taken}}` when the name is held by a prompt
  that is not this module's.
  """
  @spec ensure() :: {:ok, PhoenixKitAI.Prompt.t()} | {:error, {:prompt_error, term()}}
  def ensure, do: ensure([])

  # `:template` and `:previous` stand for `template/0` and the templates
  # shipped before, so that a test can change the template twice.
  @doc false
  @spec ensure(keyword()) :: {:ok, PhoenixKitAI.Prompt.t()} | {:error, {:prompt_error, term()}}
  def ensure(opts) do
    templates = templates(opts)

    case chosen() do
      %PhoenixKitAI.Prompt{} = prompt ->
        prompt |> follow(templates) |> PhoenixKitAI.validate_prompt()

      nil ->
        create(templates)
    end
  end

  # `prompt` as `ensure/1` read it, brought up to the template (options as
  # `ensure/1`'s): the step a test calls with a row read before a person
  # changed it, to see what the check under the lock does.
  @doc false
  @spec follow_template(PhoenixKitAI.Prompt.t(), keyword()) :: PhoenixKitAI.Prompt.t()
  def follow_template(%PhoenixKitAI.Prompt{} = prompt, opts), do: follow(prompt, templates(opts))

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp templates(opts) do
    %{
      current: Keyword.get_lazy(opts, :template, &template/0),
      previous: Keyword.get(opts, :previous, @previous_templates)
    }
  end

  defp chosen do
    case Settings.get_setting(@setting_key) do
      uuid when is_binary(uuid) and uuid != "" -> PhoenixKitAI.get_prompt(uuid)
      _ -> nil
    end
  end

  defp create(templates) do
    attrs = %{
      name: @name,
      description:
        "Rules of the photo inventory count of the warehouse. Made once; the code brings it up to a new template only while nobody has edited it.",
      content: templates.current,
      metadata: %{
        "managed_by" => @managed_by,
        "template_sha" => template_sha(templates.current)
      }
    }

    case PhoenixKitAI.create_prompt(attrs) do
      {:ok, prompt} ->
        remember(prompt)

      {:error, changeset} ->
        if taken?(changeset), do: take_existing(templates), else: invalid(changeset)
    end
  end

  # --- bringing the prompt up to the template -------------------------------------

  defp ours?(prompt), do: (prompt.metadata || %{})["managed_by"] == @managed_by

  # The module's own, switched-on prompt that still holds a template shipped
  # before. The trim is Elixir's on both sides, never the database's.
  defp outdated?(prompt, templates) do
    ours?(prompt) and prompt.enabled == true and is_binary(prompt.content) and
      template_sha(prompt.content) in templates.previous
  end

  defp follow(prompt, templates) do
    if outdated?(prompt, templates), do: update_locked(prompt, templates), else: prompt
  end

  # Checked again under the row lock: a second tab finds the current template
  # and writes nothing; a person's edit saved in between is not overwritten.
  # The update is a side job of the count: when it cannot be made - a rollback,
  # or anything raised or exited in the transaction (a lock timeout, a lost
  # connection) - it is logged and the count asks with the prompt it read.
  defp update_locked(prompt, templates) do
    case locked_update(prompt, templates) do
      {:ok, current} -> current
      {:error, reason} -> not_updated(prompt, inspect(reason))
    end
  rescue
    exception -> not_updated(prompt, inspect(exception.__struct__))
  catch
    :exit, _reason -> not_updated(prompt, "exit")
  end

  # Only what failed, never the text of the prompt.
  defp not_updated(prompt, reason) do
    Logger.warning(
      "[inventory ai] the prompt #{prompt.uuid} could not be brought up to the template: #{reason}"
    )

    prompt
  end

  defp locked_update(prompt, templates) do
    repo().transaction(fn ->
      locked =
        repo().one(
          from(p in PhoenixKitAI.Prompt, where: p.uuid == ^prompt.uuid, lock: "FOR UPDATE")
        )

      cond do
        is_nil(locked) -> repo().rollback(:gone)
        outdated?(locked, templates) -> update(locked, templates)
        true -> locked
      end
    end)
  end

  # `update_prompt/3` journals the change itself (`ai` / `prompt.updated`),
  # as the system's; the metadata is merged, not replaced: `managed_by` stays.
  defp update(prompt, templates) do
    attrs = %{
      content: templates.current,
      metadata:
        Map.merge(prompt.metadata || %{}, %{"template_sha" => template_sha(templates.current)})
    }

    case PhoenixKitAI.update_prompt(prompt, attrs, mode: "auto", actor_role: "system") do
      {:ok, updated} -> updated
      {:error, changeset} -> repo().rollback(changeset.errors)
    end
  end

  defp invalid(changeset) do
    Logger.warning("[inventory ai] the prompt could not be made: #{inspect(changeset.errors)}")
    {:error, {:prompt_error, :invalid}}
  end

  defp taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {field, {_message, opts}} ->
      field in [:name, :slug] and opts[:constraint] == :unique
    end)
  end

  # The other tab's prompt, if it is ours; a stranger's with the same name is
  # not taken over.
  defp take_existing(templates) do
    case repo().get_by(PhoenixKitAI.Prompt, name: @name) do
      %PhoenixKitAI.Prompt{} = prompt ->
        if ours?(prompt) do
          {:ok, prompt} = remember(prompt)
          prompt |> follow(templates) |> PhoenixKitAI.validate_prompt()
        else
          {:error, {:prompt_error, :name_taken}}
        end

      nil ->
        {:error, {:prompt_error, :name_taken}}
    end
  end

  defp remember(prompt) do
    Settings.update_setting_with_module(
      @setting_key,
      prompt.uuid,
      PhoenixKitWarehouse.module_key()
    )

    {:ok, prompt}
  end
end
