defmodule PhoenixKitWarehouse.Web.SettingsLiveInventoryAITest do
  use PhoenixKitWarehouse.LiveCase, async: false
  use Gettext, backend: PhoenixKitWarehouse.Gettext

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWarehouse.InventoryAI.Prompt
  alias PhoenixKitWarehouse.InventoryAI.Settings, as: AISettings

  @block "#inventory-ai-settings"
  @form "#inventory-ai-settings-form"
  @error "#inventory-ai-settings-error"
  @saved "#inventory-ai-settings-saved"

  @registry_key {PhoenixKit, :registered_modules}

  setup do
    # The permission keys `warehouse` and `ai` exist only for registered modules.
    previous = :persistent_term.get(@registry_key, :none)
    :persistent_term.put(@registry_key, [PhoenixKitWarehouse, PhoenixKitAI])

    on_exit(fn ->
      if previous == :none,
        do: :persistent_term.erase(@registry_key),
        else: :persistent_term.put(@registry_key, previous)
    end)

    PhoenixKitWarehouse.enable_system()

    # The first user registered becomes the Owner, who holds everything: let
    # it be this one, so that the users of the tests have the roles they are given.
    _owner = confirmed_user!()

    for key <- [
          AISettings.endpoint_key(),
          Prompt.setting_key(),
          AISettings.max_photos_key(),
          AISettings.max_items_key()
        ],
        do: Settings.update_setting(key, "")

    :ok
  end

  defp confirmed_user! do
    {:ok, u} =
      Auth.register_user(%{
        "email" => "inv-ai-#{System.unique_integer([:positive])}@example.com",
        "password" => "password123456789",
        "first_name" => "I",
        "last_name" => "A"
      })

    {:ok, u} = Auth.admin_confirm_user(u)
    u
  end

  defp login(conn, user) do
    token = Auth.generate_user_session_token(Auth.get_user!(user.uuid))
    conn |> Plug.Test.init_test_session(%{}) |> Plug.Conn.put_session(:user_token, token)
  end

  # An Admin-role user who may enter the warehouse pages but whose role holds
  # no `ai` permission (so that only the role itself can show the block).
  defp login_admin(conn) do
    user = confirmed_user!()
    {:ok, _} = Roles.promote_to_admin(user)

    admin_role = Roles.get_role_by_name(Role.system_roles().admin)
    Permissions.grant_permission(admin_role.uuid, "warehouse")
    Permissions.revoke_permission(admin_role.uuid, "ai")

    refute Permissions.role_has_permission?(admin_role.uuid, "ai")
    login(conn, user)
  end

  # A user whose role holds exactly `permissions`.
  defp login_holding(conn, permissions) do
    {:ok, role} = Roles.create_role(%{name: "InvAi#{System.unique_integer([:positive])}"})

    for key <- permissions, do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

    user = confirmed_user!()
    {:ok, _} = Roles.assign_role(user, role.name)
    login(conn, user)
  end

  defp endpoint!(name, attrs \\ %{}) do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(
        Map.merge(
          %{name: name, provider: "openrouter", model: "google/gemini-flash", api_key: "k"},
          attrs
        )
      )

    endpoint
  end

  defp params(attrs) do
    %{
      "inventory_ai" =>
        Map.merge(%{"endpoint_uuid" => "", "max_photos" => "10", "max_items" => "3000"}, attrs)
    }
  end

  defp open(conn), do: live(conn, Routes.path("/admin/settings/warehouse"))

  describe "who sees the block" do
    test "an administrator", %{conn: conn} do
      {:ok, lv, _} = open(login_admin(conn))

      assert has_element?(lv, @block)
      assert has_element?(lv, @form)
    end

    test "a holder of the ai module", %{conn: conn} do
      {:ok, lv, _} = open(login_holding(conn, ["warehouse", "ai"]))

      assert has_element?(lv, @block)
    end

    test "not a holder of the warehouse alone: the page is there, the block is not", %{
      conn: conn
    } do
      {:ok, lv, _} = open(login_holding(conn, ["warehouse"]))

      assert has_element?(lv, ~s(form[phx-change="set_warehouse_type"]))
      refute has_element?(lv, @block)
      refute has_element?(lv, @form)
    end
  end

  describe "the block" do
    setup %{conn: conn}, do: %{conn: login_admin(conn)}

    test "offers the enabled endpoints with the hint about photos", %{conn: conn} do
      on = endpoint!("Vision Gemini")
      off = endpoint!("Switched off", %{enabled: false})

      {:ok, lv, _} = open(conn)

      assert has_element?(lv, "#{@form} select[name='inventory_ai[endpoint_uuid]']")
      assert has_element?(lv, "#{@form} option[value='#{on.uuid}']")
      refute has_element?(lv, "#{@form} option[value='#{off.uuid}']")
      assert has_element?(lv, "#inventory-ai-endpoint-hint")

      assert lv |> element("#inventory-ai-endpoint-hint") |> render() =~
               dgettext("default", "Pick a model that can read photos.")
    end

    test "shows the saved choice and the limits", %{conn: conn} do
      endpoint = endpoint!("Chosen")
      :ok = AISettings.set_endpoint_uuid(endpoint.uuid)
      :ok = AISettings.set_max_photos(7)
      :ok = AISettings.set_max_items(1234)

      {:ok, lv, _} = open(conn)

      assert has_element?(lv, "#{@form} option[value='#{endpoint.uuid}'][selected]")
      assert has_element?(lv, "#{@form} input[name='inventory_ai[max_photos]'][value='7']")
      assert has_element?(lv, "#{@form} input[name='inventory_ai[max_items]'][value='1234']")
    end

    test "shows the defaults of the limits", %{conn: conn} do
      {:ok, lv, _} = open(conn)

      assert has_element?(lv, "#{@form} input[name='inventory_ai[max_photos]'][value='10']")
      assert has_element?(lv, "#{@form} input[name='inventory_ai[max_items]'][value='3000']")
    end

    test "saves the choice and the limits", %{conn: conn} do
      endpoint = endpoint!("To save")
      {:ok, lv, _} = open(conn)

      lv
      |> form(
        @form,
        params(%{"endpoint_uuid" => endpoint.uuid, "max_photos" => "12", "max_items" => "2 500"})
      )
      |> render_submit()

      assert has_element?(lv, @saved)
      refute has_element?(lv, @error)
      assert AISettings.endpoint_uuid() == endpoint.uuid
      assert AISettings.max_photos() == 12
      assert AISettings.max_items() == 2500
    end

    test "an empty choice clears the endpoint (the button goes away)", %{conn: conn} do
      endpoint = endpoint!("To clear")
      :ok = AISettings.set_endpoint_uuid(endpoint.uuid)
      {:ok, lv, _} = open(conn)

      lv |> form(@form, params(%{"endpoint_uuid" => ""})) |> render_submit()

      assert AISettings.endpoint_uuid() == nil
    end

    test "refuses a limit that is not a whole number or out of range, and saves nothing", %{
      conn: conn
    } do
      endpoint = endpoint!("Not saved")
      {:ok, lv, _} = open(conn)

      for bad <- ["0", "-3", "2.5", "many", "", "100000"] do
        lv
        |> form(@form, params(%{"endpoint_uuid" => endpoint.uuid, "max_photos" => bad}))
        |> render_submit()

        assert has_element?(lv, @error), "max_photos #{inspect(bad)} was accepted"
        refute has_element?(lv, @saved)
      end

      assert AISettings.endpoint_uuid() == nil
      assert AISettings.max_photos() == 10

      lv |> form(@form, params(%{"max_items" => "0"})) |> render_submit()
      assert has_element?(lv, @error)
      assert AISettings.max_items() == 3000
    end

    test "refuses an endpoint that is not on the list (a stale page, a forged event)", %{
      conn: conn
    } do
      {:ok, lv, _} = open(conn)
      gone = Ecto.UUID.generate()

      render_hook(lv, "save_inventory_ai", params(%{"endpoint_uuid" => gone}))

      assert has_element?(lv, @error)
      assert AISettings.endpoint_uuid() == nil
    end

    test "a failed save after a good one does not still say saved", %{conn: conn} do
      {:ok, lv, _} = open(conn)

      lv |> form(@form, params(%{"max_photos" => "12"})) |> render_submit()
      assert has_element?(lv, @saved)

      lv |> form(@form, params(%{"max_photos" => "0"})) |> render_submit()

      assert has_element?(lv, @error)
      refute has_element?(lv, @saved)
      assert AISettings.max_photos() == 12

      lv |> form(@form, params(%{"max_photos" => "13"})) |> render_submit()

      assert has_element?(lv, @saved)
      refute has_element?(lv, @error)
    end

    test "an endpoint switched off since it was saved stays chosen, named, and survives a save",
         %{conn: conn} do
      endpoint = endpoint!("Was fine")
      :ok = AISettings.set_endpoint_uuid(endpoint.uuid)
      {:ok, _} = PhoenixKitAI.update_endpoint(endpoint, %{enabled: false})

      {:ok, lv, _} = open(conn)

      assert has_element?(lv, "#{@form} option[value='#{endpoint.uuid}'][selected]")
      assert lv |> element("#{@form} option[value='#{endpoint.uuid}']") |> render() =~ "Was fine"

      lv
      |> form(@form, params(%{"endpoint_uuid" => endpoint.uuid, "max_photos" => "11"}))
      |> render_submit()

      assert has_element?(lv, @saved)
      assert AISettings.endpoint_uuid() == endpoint.uuid
      assert AISettings.max_photos() == 11
    end

    test "a saved endpoint that is gone shows as unavailable and survives a save", %{conn: conn} do
      gone = Ecto.UUID.generate()
      :ok = AISettings.set_endpoint_uuid(gone)

      {:ok, lv, _} = open(conn)

      assert lv |> element("#{@form} option[value='#{gone}']") |> render() =~
               dgettext("default", "Unavailable endpoint")

      lv
      |> form(@form, params(%{"endpoint_uuid" => gone, "max_photos" => "9"}))
      |> render_submit()

      assert has_element?(lv, @saved)
      assert AISettings.endpoint_uuid() == gone
    end

    test "the list is read again when saving: an endpoint made after the page opened is taken, one switched off is refused",
         %{conn: conn} do
      later_off = endpoint!("Goes off")
      {:ok, lv, _} = open(conn)
      later_on = endpoint!("Made later")
      {:ok, _} = PhoenixKitAI.update_endpoint(later_off, %{enabled: false})

      render_hook(lv, "save_inventory_ai", params(%{"endpoint_uuid" => later_off.uuid}))
      assert has_element?(lv, @error)
      assert AISettings.endpoint_uuid() == nil

      render_hook(lv, "save_inventory_ai", params(%{"endpoint_uuid" => later_on.uuid}))
      assert has_element?(lv, @saved)
      assert AISettings.endpoint_uuid() == later_on.uuid
    end

    test "a value that cannot be written is told, not saved", %{conn: conn} do
      # Written by hand, not a uuid: the page offers it as the saved choice,
      # the settings refuse to take it back.
      Settings.update_setting(AISettings.endpoint_key(), "not-a-uuid")
      {:ok, lv, _} = open(conn)

      render_hook(
        lv,
        "save_inventory_ai",
        params(%{"endpoint_uuid" => "not-a-uuid", "max_photos" => "5"})
      )

      assert has_element?(lv, @error)

      assert lv |> element(@error) |> render() =~
               dgettext("default", "The settings could not be saved.")

      refute has_element?(lv, @saved)
      assert AISettings.max_photos() == 10
    end

    test "a malformed event is told, the page stays", %{conn: conn} do
      {:ok, lv, _} = open(conn)

      render_hook(lv, "save_inventory_ai", %{"inventory_ai" => "x"})
      assert has_element?(lv, @error)

      render_hook(lv, "save_inventory_ai", %{})
      assert has_element?(lv, @error)
      assert has_element?(lv, @form)
    end

    test "links to the prompt: the list while there is none, its edit page once made", %{
      conn: conn
    } do
      {:ok, lv, _} = open(conn)

      assert lv |> element("#inventory-ai-prompt-link") |> render() =~
               ~s(href="#{Routes.path("/admin/ai/prompts")}")

      {:ok, prompt} = Prompt.ensure()
      {:ok, lv, _} = open(conn)

      assert lv |> element("#inventory-ai-prompt-link") |> render() =~
               ~s(href="#{Routes.path("/admin/ai/prompts/#{prompt.uuid}/edit")}")
    end
  end

  describe "the event without the access" do
    test "does not save: the check is in the handler, not only in the render", %{conn: conn} do
      endpoint = endpoint!("Forged")
      {:ok, lv, _} = open(login_holding(conn, ["warehouse"]))

      # An event that would be valid for a person who may send it: no endpoint
      # to be refused for, only the limits.
      render_hook(lv, "save_inventory_ai", params(%{"max_photos" => "20", "max_items" => "100"}))

      render_hook(
        lv,
        "save_inventory_ai",
        params(%{"endpoint_uuid" => endpoint.uuid, "max_photos" => "20", "max_items" => "100"})
      )

      assert AISettings.endpoint_uuid() == nil
      assert AISettings.max_photos() == 10
      assert AISettings.max_items() == 3000
      refute has_element?(lv, @block)
    end

    test "the page of the warehouse settings still works for them", %{conn: conn} do
      {:ok, lv, _} = open(login_holding(conn, ["warehouse"]))

      render_change(lv, "set_default_location", %{"value" => ""})
      assert has_element?(lv, ~s(form[phx-change="set_default_location"]))
    end
  end
end
