defmodule PhoenixKitWarehouse.UkLocaleTest do
  @moduledoc """
  Pins the Ukrainian (`uk`) catalog: no msgid that default.pot lacks, no empty
  or fuzzy entries, live `dgettext` output, and a correct plural-forms header.

  The plural msgids (the photo inventory's counts, `dngettext`) are checked
  like the others, every form filled; the plural rule is verified from the
  header the catalog declares.
  """

  use ExUnit.Case, async: true

  import Gettext, only: [with_locale: 2]

  @gettext_dir Path.expand("../../priv/gettext", __DIR__)
  @pot_path Path.join(@gettext_dir, "default.pot")
  @uk_path Path.join([@gettext_dir, "uk", "LC_MESSAGES", "default.po"])

  defp t(msgid), do: Gettext.dgettext(PhoenixKitWarehouse.Gettext, "default", msgid)

  defp messages(path) do
    assert File.exists?(path), "missing catalog: #{path}"
    path |> Expo.PO.parse_file!() |> Map.fetch!(:messages)
  end

  defp singular_ids(messages) do
    for %Expo.Message.Singular{msgid: msgid} <- messages, do: IO.iodata_to_binary(msgid)
  end

  defp plural_ids(messages) do
    for %Expo.Message.Plural{msgid: msgid} <- messages, do: IO.iodata_to_binary(msgid)
  end

  defp bindings_by_msgid(messages) do
    for %Expo.Message.Singular{msgid: id, msgstr: str} <- messages, into: %{} do
      {IO.iodata_to_binary(id), %{msgid: bindings(id), msgstr: bindings(str)}}
    end
  end

  defp bindings(iodata) do
    ~r/%\{\w+\}/ |> Regex.scan(IO.iodata_to_binary(iodata)) |> List.flatten() |> Enum.sort()
  end

  describe "uk catalog" do
    test "has no msgid that is absent from default.pot" do
      pot_ids = @pot_path |> messages() |> singular_ids() |> MapSet.new()
      uk_ids = @uk_path |> messages() |> singular_ids() |> MapSet.new()

      assert MapSet.size(pot_ids) > 0
      assert MapSet.size(uk_ids) > 0
      assert MapSet.difference(uk_ids, pot_ids) == MapSet.new()

      pot_plurals = @pot_path |> messages() |> plural_ids() |> MapSet.new()
      uk_plurals = @uk_path |> messages() |> plural_ids() |> MapSet.new()
      assert MapSet.difference(uk_plurals, pot_plurals) == MapSet.new()
    end

    test "translates every msgid of default.pot" do
      pot_ids = @pot_path |> messages() |> singular_ids() |> MapSet.new()
      uk_ids = @uk_path |> messages() |> singular_ids() |> MapSet.new()

      assert MapSet.difference(pot_ids, uk_ids) |> Enum.sort() == []

      pot_plurals = @pot_path |> messages() |> plural_ids() |> MapSet.new()
      uk_plurals = @uk_path |> messages() |> plural_ids() |> MapSet.new()
      assert MapSet.difference(pot_plurals, uk_plurals) |> Enum.sort() == []
    end

    test "has no empty msgstr and no fuzzy entries" do
      uk_messages = messages(@uk_path)

      empty =
        for %Expo.Message.Singular{msgid: id, msgstr: str} <- uk_messages,
            IO.iodata_to_binary(str) == "",
            do: IO.iodata_to_binary(id)

      empty_plurals =
        for %Expo.Message.Plural{msgid: id, msgstr: forms} <- uk_messages,
            map_size(forms) != 3 or Enum.any?(Map.values(forms), &(IO.iodata_to_binary(&1) == "")),
            do: IO.iodata_to_binary(id)

      fuzzy =
        for %{msgid: id} = message <- uk_messages,
            Enum.any?(message.flags, &("fuzzy" in &1)),
            do: IO.iodata_to_binary(id)

      assert empty_plurals == []

      assert empty == []
      assert fuzzy == []
    end

    test "declares the Ukrainian plural rule and it picks the right branch" do
      po = Expo.PO.parse_file!(@uk_path)
      assert [header] = Expo.Messages.get_header(po, "Plural-Forms")
      assert {:ok, plural_forms} = Expo.PluralForms.parse(header)

      assert plural_forms.nplurals == 3

      index = fn n -> Expo.PluralForms.index(plural_forms, n) end

      for n <- [1, 21, 101], do: assert(index.(n) == 0, "n=#{n}")
      for n <- [2, 3, 4, 22, 24, 102], do: assert(index.(n) == 1, "n=#{n}")
      for n <- [0, 5, 11, 12, 14, 20, 25, 111], do: assert(index.(n) == 2, "n=#{n}")
    end
  end

  describe "placeholders" do
    test "every msgstr keeps the %{...} bindings of its msgid" do
      pot = @pot_path |> messages() |> bindings_by_msgid()
      uk = @uk_path |> messages() |> bindings_by_msgid()

      shared = for msgid <- Map.keys(pot), Map.has_key?(uk, msgid), do: msgid

      # guard against a vacuous pass: some shared msgids really carry bindings
      assert Enum.any?(shared, &(pot[&1].msgid != []))

      mismatched =
        for msgid <- shared,
            uk[msgid].msgstr != pot[msgid].msgid,
            do: msgid

      assert mismatched == []
    end
  end

  describe "live lookups" do
    test "uk resolves known strings to Ukrainian" do
      with_locale("uk", fn ->
        for msgid <- [
              "Warehouse",
              "Supplier",
              "Posted",
              "Internal orders",
              "New internal order",
              "— select supplier —"
            ] do
          translated = t(msgid)
          refute translated == msgid, "#{msgid} is not translated into uk"
          assert translated =~ ~r/\p{Cyrillic}/u, "#{msgid} has no Cyrillic in uk"
        end
      end)
    end

    test "uk is a known locale of the backend" do
      assert "uk" in Gettext.known_locales(PhoenixKitWarehouse.Gettext)
    end
  end
end
