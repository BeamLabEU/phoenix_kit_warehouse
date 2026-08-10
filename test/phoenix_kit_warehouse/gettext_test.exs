defmodule PhoenixKitWarehouse.GettextTest do
  @moduledoc """
  Pins live `dgettext` output for every bundled locale (en/et/ru).

  Guards against gettext.merge fuzzy pollution — a past incident in this
  workspace fuzzy-matched unrelated msgids and shipped wrong ENGLISH strings,
  so `en` is asserted here too, not just the translated locales.
  """

  use ExUnit.Case, async: true

  import Gettext, only: [with_locale: 2]

  defp t(msgid), do: Gettext.dgettext(PhoenixKitWarehouse.Gettext, "default", msgid)

  test "en returns the msgid verbatim" do
    with_locale("en", fn ->
      assert t("Warehouse") == "Warehouse"
      assert t("Internal orders") == "Internal orders"
      assert t("Goods receipt") == "Goods receipt"
      assert t("Posted") == "Posted"
      assert t("— select supplier —") == "— select supplier —"
    end)
  end

  test "et translations (ported terminology)" do
    with_locale("et", fn ->
      assert t("Warehouse") == "Ladu"
      assert t("Supplier") == "Tarnija"
      assert t("New internal order") == "Uus sisetellimus"
      assert t("New supplier order") == "Uus tarnijatellimus"
      assert t("Warehouse settings") == "Lao seaded"
      assert t("— select supplier —") == "— vali tarnija —"
    end)
  end

  test "ru translations (ported terminology)" do
    with_locale("ru", fn ->
      assert t("Warehouse") == "Склад"
      assert t("Supplier") == "Поставщик"
      assert t("New internal order") == "Новый внутренний заказ"
      assert t("New supplier order") == "Новый заказ поставщику"
      assert t("Warehouse settings") == "Настройки склада"
      assert t("— select supplier —") == "— выберите поставщика —"
    end)
  end

  test "no locale leaks another locale's strings" do
    with_locale("et", fn ->
      refute t("Posted") == "Проведён"
    end)

    with_locale("ru", fn ->
      refute t("Posted") == "Sisestatud"
    end)
  end

  describe "permission_metadata/0 gettext wiring" do
    # Core ≥ 1.7.206 translates permission-matrix labels through the
    # {gettext_backend, gettext_domain} pair a module declares, dropping any
    # backend that fails its __gettext__/1 check at boot.
    test "declares this module's backend and the default domain" do
      meta = PhoenixKitWarehouse.permission_metadata()

      assert meta.gettext_backend == PhoenixKitWarehouse.Gettext
      assert meta.gettext_domain == "default"
    end

    test "the declared pair passes core's gate and translates the label" do
      %{gettext_backend: backend, gettext_domain: domain, label: label} =
        PhoenixKitWarehouse.permission_metadata()

      assert Code.ensure_loaded?(backend)
      assert function_exported?(backend, :__gettext__, 1)

      with_locale("ru", fn ->
        assert Gettext.dgettext(backend, domain, label) == "Склад"
      end)

      with_locale("et", fn ->
        assert Gettext.dgettext(backend, domain, label) == "Ladu"
      end)
    end
  end
end
