# PhoenixKit Warehouse

Warehouse module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

A drop-in PhoenixKit module — add it to a host app's deps and it is
auto-discovered, adding a **Warehouse** section to the admin panel. Like every
PhoenixKit module it has no endpoint, router, or Ecto repo of its own; it
borrows the host's via `phoenix_kit`.

> **Status:** scaffold. Project configuration is in place; module code
> (schemas, contexts, admin UI, migrations) is not implemented yet.

## Planned scope

- **Inventory / stock** — warehouses, locations, and on-hand quantities.
- **Goods receipts / issues** — stock movements in and out.
- Integration with the Manufacturing module (goods issues / receipts) and
  other PhoenixKit modules.

## Installation

Add to your host app's `mix.exs`:

```elixir
{:phoenix_kit_warehouse, "~> 0.3"}
```

Then fetch deps, apply the module's tables, and enable it in
**Admin → Modules**:

```bash
mix deps.get
mix phoenix_kit.update
```

## Development

See [`AGENTS.md`](AGENTS.md) for architecture, conventions, testing, and the
release checklist.

## License

MIT — see [LICENSE](LICENSE).
