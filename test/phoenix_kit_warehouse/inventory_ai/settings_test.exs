defmodule PhoenixKitWarehouse.InventoryAI.SettingsTest do
  use PhoenixKitWarehouse.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Settings.Setting
  alias PhoenixKitWarehouse.InventoryAI.Prompt
  alias PhoenixKitWarehouse.InventoryAI.Settings, as: AISettings

  @keys ~w(
    warehouse_inventory_ai_endpoint_uuid
    warehouse_inventory_ai_prompt_uuid
    warehouse_inventory_ai_max_photos
    warehouse_inventory_ai_max_items
  )

  setup do
    for key <- @keys, do: Settings.update_setting(key, "")
    :ok
  end

  test "the keys are the ones of the spec" do
    assert AISettings.endpoint_key() == "warehouse_inventory_ai_endpoint_uuid"
    assert Prompt.setting_key() == "warehouse_inventory_ai_prompt_uuid"
    assert AISettings.max_photos_key() == "warehouse_inventory_ai_max_photos"
    assert AISettings.max_items_key() == "warehouse_inventory_ai_max_items"
  end

  describe "endpoint" do
    test "is nil until chosen" do
      assert AISettings.endpoint_uuid() == nil
    end

    test "is stored and cleared" do
      uuid = Ecto.UUID.generate()

      assert :ok = AISettings.set_endpoint_uuid(uuid)
      assert AISettings.endpoint_uuid() == uuid
      assert Settings.get_setting(AISettings.endpoint_key()) == uuid

      assert :ok = AISettings.set_endpoint_uuid(nil)
      assert AISettings.endpoint_uuid() == nil

      assert :ok = AISettings.set_endpoint_uuid(uuid)
      assert :ok = AISettings.set_endpoint_uuid("")
      assert AISettings.endpoint_uuid() == nil
    end

    test "clearing what was never set is fine" do
      Repo.delete_all(from(s in Setting, where: s.key == ^AISettings.endpoint_key()))

      assert :ok = AISettings.set_endpoint_uuid(nil)
      assert AISettings.endpoint_uuid() == nil
    end

    test "a value that is not a uuid is refused and the old choice stays" do
      uuid = Ecto.UUID.generate()
      :ok = AISettings.set_endpoint_uuid(uuid)

      assert AISettings.set_endpoint_uuid("not-a-uuid") == {:error, :invalid}
      assert AISettings.endpoint_uuid() == uuid
    end
  end

  describe "prompt uuid" do
    test "is read from the setting the prompt module writes" do
      assert AISettings.prompt_uuid() == nil

      {:ok, prompt} = Prompt.ensure()
      assert AISettings.prompt_uuid() == prompt.uuid
    end
  end

  describe "max photos" do
    test "defaults to 10" do
      assert AISettings.max_photos() == 10
    end

    test "is stored as a whole number" do
      assert :ok = AISettings.set_max_photos(12)
      assert AISettings.max_photos() == 12
    end

    test "refuses zero, negative, too many and not whole" do
      :ok = AISettings.set_max_photos(12)

      for bad <- [0, -1, 1000, 2.5, "12", nil] do
        assert AISettings.set_max_photos(bad) == {:error, :invalid}
      end

      assert AISettings.max_photos() == 12
    end

    test "a stored value that is not a number falls back to the default" do
      Settings.update_setting(AISettings.max_photos_key(), "many")
      assert AISettings.max_photos() == 10

      Settings.update_setting(AISettings.max_photos_key(), "0")
      assert AISettings.max_photos() == 10
    end
  end

  describe "max items" do
    test "defaults to 3000" do
      assert AISettings.max_items() == 3000
    end

    test "is stored as a whole number" do
      assert :ok = AISettings.set_max_items(1500)
      assert AISettings.max_items() == 1500
    end

    test "refuses zero, negative, absurd and not whole" do
      :ok = AISettings.set_max_items(1500)

      for bad <- [0, -5, 10_000_000, 1.5, "1500", nil] do
        assert AISettings.set_max_items(bad) == {:error, :invalid}
      end

      assert AISettings.max_items() == 1500
    end

    test "a stored value that is not a number falls back to the default" do
      Settings.update_setting(AISettings.max_items_key(), "")
      assert AISettings.max_items() == 3000
    end
  end
end
