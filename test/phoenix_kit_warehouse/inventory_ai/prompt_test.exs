defmodule PhoenixKitWarehouse.InventoryAI.PromptTest do
  use PhoenixKitWarehouse.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKitWarehouse.InventoryAI.Prompt

  @managed_by "phoenix_kit_warehouse"

  setup do
    Settings.update_setting(Prompt.setting_key(), "")
    :ok
  end

  defp ours do
    Enum.filter(PhoenixKitAI.list_prompts(), &((&1.metadata || %{})["managed_by"] == @managed_by))
  end

  defp edit!(prompt, attrs) do
    {:ok, updated} = PhoenixKitAI.update_prompt(prompt, attrs)
    updated
  end

  describe "template" do
    test "carries the rules of the count" do
      text = Prompt.template()

      for rule <- [
            "object_key",
            "CATALOGUE",
            "catalogue_no",
            "alternatives",
            "open_fill",
            "0.4",
            "0.35",
            "units_per_package",
            "loose_units",
            "quantity",
            "count_confidence",
            "off_purpose",
            "nothing_found",
            "★",
            "120"
          ] do
        assert text =~ rule, "the template has no word on #{rule}"
      end
    end

    test "lists the objects no catalogue line fits; nothing found is only an empty view" do
      text = Prompt.template()

      assert text =~ "List every stock object you see, also when no `CATALOGUE` line fits it"
      assert text =~ "`nothing_found` is `true` only when no stock objects are visible at all"
      refute text =~ "nothing you can recognise"
    end

    test "counts the pieces it can see; packages only when the inside cannot be seen" do
      text = Prompt.template()

      assert text =~ "In a transparent bag"
      assert text =~ "`closed_packages` and `open_packages` are then 0"
      assert text =~ "Count packages only when their inside cannot be seen"
    end

    test "an item kept in packs is counted in packs, also through a transparent bag" do
      assert Prompt.template() =~ "has the unit `pack` is counted in packs"
      assert Prompt.template() =~ "also when its pieces can be seen through it"
    end

    test "a bag of several kinds is one entry per kind, each with its own key" do
      assert Prompt.template() =~ "gives one entry per kind, each with its own `object_key`"
    end

    test "several packs of one kind are packs times the pieces of one, not loose pieces" do
      text = Prompt.template()
      assert text =~ "several packs of one kind and you can count every piece in one of them"
      assert text =~ "count the packs in `closed_packages`, with `units_per_package` as above"
      assert text =~ "or when there are several packs of one kind."
      assert text =~ "then `count_confidence` is at most `medium`"
    end

    test "the template it replaced is a shipped one, so an unedited prompt follows it" do
      assert "b5df51bf350074448dace13205dff7f7edc5a91492d7c87987110fb96f6e9f3e" in Prompt.previous_template_shas()
    end

    test "has no placeholders" do
      refute Prompt.template() =~ "{{"
    end

    test "is trimmed and the sha is taken of the trimmed text" do
      assert Prompt.template() == String.trim(Prompt.template())
      assert Prompt.template_sha("  a \n") == Prompt.template_sha("a")
      assert Prompt.template_sha("a") =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "the current template is not among the ones shipped before" do
      refute Prompt.template_sha(Prompt.template()) in Prompt.previous_template_shas()
    end
  end

  describe "ensure/0: making the prompt" do
    test "makes it from the template and remembers its uuid" do
      assert {:ok, prompt} = Prompt.ensure()

      assert prompt.name == Prompt.name()
      assert prompt.content == Prompt.template()
      assert prompt.enabled
      assert prompt.metadata["managed_by"] == @managed_by
      assert prompt.metadata["template_sha"] == Prompt.template_sha(Prompt.template())
      assert Settings.get_setting(Prompt.setting_key()) == prompt.uuid
    end

    test "a second call finds the same prompt by the uuid in the setting" do
      {:ok, first} = Prompt.ensure()
      {:ok, second} = Prompt.ensure()

      assert second.uuid == first.uuid
      assert length(ours()) == 1
    end

    test "finds it by uuid, not by name: a renamed prompt is still the one" do
      {:ok, first} = Prompt.ensure()
      edit!(first, %{name: "Renamed by a person"})

      assert {:ok, again} = Prompt.ensure()
      assert again.uuid == first.uuid
      assert again.name == "Renamed by a person"
      assert length(ours()) == 1
    end

    test "a setting naming a prompt that is gone makes a new one" do
      {:ok, first} = Prompt.ensure()
      {:ok, _} = PhoenixKitAI.delete_prompt(first)

      assert {:ok, second} = Prompt.ensure()
      refute second.uuid == first.uuid
      assert Settings.get_setting(Prompt.setting_key()) == second.uuid
    end

    test "a setting that is not a uuid makes a new prompt" do
      Settings.update_setting(Prompt.setting_key(), "not-a-uuid")

      assert {:ok, prompt} = Prompt.ensure()
      assert Settings.get_setting(Prompt.setting_key()) == prompt.uuid
    end
  end

  describe "ensure/0: two tabs making it at once (the name is taken)" do
    test "takes the prompt the other tab made, found by name and owner" do
      {:ok, other_tab} = Prompt.ensure()
      Settings.update_setting(Prompt.setting_key(), "")

      assert {:ok, prompt} = Prompt.ensure()
      assert prompt.uuid == other_tab.uuid
      assert Settings.get_setting(Prompt.setting_key()) == other_tab.uuid
      assert length(ours()) == 1
    end

    test "a stranger's prompt with the same name is not taken over" do
      {:ok, stranger} =
        PhoenixKitAI.create_prompt(%{name: Prompt.name(), content: "somebody else's text"})

      assert Prompt.ensure() == {:error, {:prompt_error, :name_taken}}
      assert Settings.get_setting(Prompt.setting_key()) in [nil, ""]
      assert PhoenixKitAI.get_prompt(stranger.uuid).content == "somebody else's text"
    end
  end

  describe "ensure/1: following a new template" do
    @v1 "Rules, version one."
    @v2 "Rules, version two."

    defp v1_sha, do: Prompt.template_sha(@v1)

    test "brings its own, switched-on prompt that holds a template shipped before up to date" do
      {:ok, made} = Prompt.ensure(template: @v1)
      assert made.content == @v1

      assert {:ok, updated} = Prompt.ensure(template: @v2, previous: [v1_sha()])

      assert updated.uuid == made.uuid
      assert updated.content == @v2
      assert updated.metadata["managed_by"] == @managed_by
      assert updated.metadata["template_sha"] == Prompt.template_sha(@v2)
      assert PhoenixKitAI.get_prompt(made.uuid).content == @v2
    end

    test "leaves a prompt a person edited alone" do
      {:ok, made} = Prompt.ensure(template: @v1)
      edit!(made, %{content: "The foreman's own rules."})

      assert {:ok, same} = Prompt.ensure(template: @v2, previous: [v1_sha()])
      assert same.content == "The foreman's own rules."
    end

    test "leaves a prompt alone when the template it holds is not a shipped one" do
      {:ok, made} = Prompt.ensure(template: @v1)

      assert {:ok, same} = Prompt.ensure(template: @v2, previous: [])
      assert same.content == @v1
      assert same.uuid == made.uuid
    end

    test "does not touch a prompt that is not its own, even holding an old template" do
      {:ok, mine} = Prompt.ensure(template: @v1)
      edit!(mine, %{metadata: %{}})

      assert {:ok, same} = Prompt.ensure(template: @v2, previous: [v1_sha()])
      assert same.content == @v1
    end

    test "an old template with a person's trailing whitespace is still recognised" do
      {:ok, made} = Prompt.ensure(template: @v1)
      edit!(made, %{content: @v1 <> "\n\n"})

      assert {:ok, updated} = Prompt.ensure(template: @v2, previous: [v1_sha()])
      assert updated.content == @v2
    end

    test "the row is checked again under the lock: an edit saved after the read is kept" do
      {:ok, made} = Prompt.ensure(template: @v1)
      stale = PhoenixKitAI.get_prompt(made.uuid)
      edit!(made, %{content: "Edited in the other tab."})

      followed = Prompt.follow_template(stale, template: @v2, previous: [v1_sha()])

      assert followed.content == "Edited in the other tab."
      assert PhoenixKitAI.get_prompt(made.uuid).content == "Edited in the other tab."
    end

    test "a second tab finding the current template writes nothing" do
      {:ok, made} = Prompt.ensure(template: @v1)
      {:ok, updated} = Prompt.ensure(template: @v2, previous: [v1_sha()])
      stale = %{made | content: @v1}

      followed = Prompt.follow_template(stale, template: @v2, previous: [v1_sha()])

      assert followed.content == updated.content
      assert PhoenixKitAI.get_prompt(made.uuid).updated_at == updated.updated_at
    end
  end

  describe "ensure/1: an update that cannot be made" do
    @v1 "Rules, version one."
    @v2 "Rules, version two."

    # The update is a side job of the count: whatever goes wrong, the count
    # asks with the prompt it read, the failure is logged without the text.
    defp outdated_prompt! do
      {:ok, made} = Prompt.ensure(template: @v1)
      {made, [Prompt.template_sha(@v1)]}
    end

    test "an update the prompt module refuses leaves the prompt as read" do
      {made, previous} = outdated_prompt!()

      log =
        capture_log(fn ->
          # An empty template is refused by the prompt's own changeset.
          assert Prompt.follow_template(made, template: "", previous: previous) == made
        end)

      assert log =~ "could not be brought up to the template"
      assert log =~ made.uuid
      refute log =~ @v1
      assert PhoenixKitAI.get_prompt(made.uuid).content == @v1
    end

    test "an exception inside the transaction is logged and the prompt as read is used" do
      {made, previous} = outdated_prompt!()

      log =
        capture_log(fn ->
          assert Prompt.follow_template(made, template: nil, previous: previous) == made
        end)

      assert log =~ "could not be brought up to the template"
      assert PhoenixKitAI.get_prompt(made.uuid).content == @v1
    end

    test "a prompt deleted after the read is used as read, nothing is made" do
      {made, previous} = outdated_prompt!()
      {:ok, _} = PhoenixKitAI.delete_prompt(made)

      log =
        capture_log(fn ->
          assert Prompt.follow_template(made, template: @v2, previous: previous) == made
        end)

      assert log =~ "could not be brought up to the template"
      assert PhoenixKitAI.get_prompt(made.uuid) == nil
      assert ours() == []
    end
  end

  describe "ensure/0: a switched-off prompt" do
    test "is an error, not a reason to make another" do
      {:ok, made} = Prompt.ensure()
      edit!(made, %{enabled: false})

      assert Prompt.ensure() == {:error, {:prompt_error, :disabled}}
      assert length(ours()) == 1
      assert Settings.get_setting(Prompt.setting_key()) == made.uuid
    end

    test "is not brought up to a new template either" do
      {:ok, made} = Prompt.ensure(template: @v1)
      edit!(made, %{enabled: false})

      assert Prompt.ensure(template: @v2, previous: [v1_sha()]) ==
               {:error, {:prompt_error, :disabled}}

      assert PhoenixKitAI.get_prompt(made.uuid).content == @v1
    end
  end
end
