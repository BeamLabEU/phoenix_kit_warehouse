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
end
