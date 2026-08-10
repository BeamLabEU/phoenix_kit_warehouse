# Dialyzer warnings that are artefacts of a dependency's types rather than
# defects here. Keep this list short and justified — every entry is a warning
# nobody will look at again.
[
  # Each context's `lock_status_step/3` builds a multi with `Ecto.Multi.new()`
  # and hands it straight to `Ecto.Multi.run/3`. `Ecto.Multi.t()` is `@opaque`,
  # but dialyzer sees through `new/0` to the concrete `%Ecto.Multi{}` struct and
  # then reports passing it back into Ecto as an opaqueness mismatch. The code
  # is the documented Ecto idiom; rewriting the call as
  # `Ecto.Multi.new() |> Ecto.Multi.run(...)` was tried and only moves the
  # column the warning points at.
  {"lib/phoenix_kit_warehouse/goods_issues.ex", :call_without_opaque},
  {"lib/phoenix_kit_warehouse/goods_receipts.ex", :call_without_opaque},
  {"lib/phoenix_kit_warehouse/internal_orders.ex", :call_without_opaque},
  {"lib/phoenix_kit_warehouse/inventories.ex", :call_without_opaque},
  {"lib/phoenix_kit_warehouse/supplier_orders.ex", :call_without_opaque},
  {"lib/phoenix_kit_warehouse/transfers.ex", :call_without_opaque}
]
