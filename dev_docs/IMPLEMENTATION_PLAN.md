<!-- ПРИМЕЧАНИЕ ОРКЕСТРАТОРА 2026-07-10: решения по открытым вопросам планировщика -->
> **Решения по открытым вопросам (2026-07-10):**
> 1. **Мин. остаток — глобально на позицию** (Σ по складам) в волне 1; гранулярность по складам — потом (своя миграция = дёшево).
> 2. **Отмена перемещения — ДОБАВИТЬ**: cancel из draft (без проводок) и из in_transit (реверс-проводка возврата на источник). Небольшая задача рядом с T-блоком перемещений.
> 3. **«Сальдо» оборотов = текущий остаток** (исторического журнала нет) — принято для волны 1; ledger-журнал — отдельная будущая тема.
> 4. **XLS-экспорт оборотов — вне волны 1** (нет прецедента в модуле) — принято.
> 5. **Селектор склада в формах InternalOrder/SupplierOrder — отложен на волну 2** (вне §10-а; поля `location_uuid` уже есть, заполняются дефолтом).
>
> **Стыковка с locations:** контракт — `PlacePicker` LiveComponent (`{:place_picker_select, id, %{location_uuid, space_uuid}}`) и `PhoenixKitLocations.Spaces.full_path/2`; складские задачи, зависящие от пикера, имеют текстовый fallback до готовности locations v0.5.

> Ревью-правки (многораундовое ревью 2026-07-10: GLM High+Max / Sonnet / Kimi / Vibe / Opus-max) интегрированы в тексты задач.



# План: phoenix_kit_warehouse — волна 1 (мульти-склад, перемещения, дефицит, обороты, связанные документы)

## Цель

Реализовать первую очередь доработок склада, утверждённую в `dev_docs/DEVELOPMENT_PLAN.md` §10-а (2026-07-10):
1. Мульти-склад (§1) — `Stock.location_uuid` и location-поля документов начинают указывать на реальные `phoenix_kit_locations` записи типа Warehouse.
2. Перемещения (§2) — новый тип документа между складами.
3. Контроль дефицита (§5, полный вариант) — мин. остаток, «доступно = остаток − резерв», переход в заказ поставщику.
4. Обороты (§8, без экспорта — прецедента XLS в модуле нет).
5. Связанные документы — список-MVP (§7).

## Текущее состояние (проверено чтением кода 2026-07-10)

- `Stock.location_uuid` и `location_uuid` во всех документах (`GoodsReceipt`, `GoodsIssue`, `InternalOrder`, `SupplierOrder`, `InventoryDocument`) уже существуют как мягкий `Ecto.UUID` без FK. Настройки `warehouse_location_type_uuid` / `warehouse_default_location_uuid` уже реализованы в `StockLedger` и управляются через `Web.SettingsLive` (`/admin/settings/warehouse`) — **значит, задача 1 не требует новой миграции**, только доводки логики и UI.
- **`phoenix_kit_locations` v0.2.1**: пикер места (`PlacePicker` LiveComponent) и `PhoenixKitLocations.Spaces.full_path/2` (не `Paths.full_path/1` — `lib/phoenix_kit_locations/paths.ex` содержит только `Routes.path`-хелперы для URL, к построению пути локации не относится) **ещё не реализованы**. Есть `PhoenixKitLocations.Locations.list_locations(type_uuid: ...)` и `get_location/1` — этого достаточно. **Решение: используем обычный `<select>`**, без ожидания picker-компонента locations (graceful text/select-fallback). Замена на богатый picker — T23 (хвост волны 1, опционально).
- **Реальный источник таблиц склада сегодня**: актуальный dep `/www/app/deps/phoenix_kit` уже имеет `@current_version 140`, и `v140.ex` в его составе — это и есть штатная складская core-миграция (создаёт те же 6 таблиц, что и bootstrap-миграция самого Andi: `/www/app/priv/repo/migrations/20260708140000_create_phoenix_kit_warehouse_tables.exs`; обе idempotent, конфликта между ними нет). Это НЕ «стоп-гэп до публикации V140» — V140 уже реальность в текущем deps. Для нас это не блокер: новые таблицы (Transfers, MinStock), которых нет ни в bootstrap-миграции, ни в core V140, идут через **собственный** `migration_module/0` пакета `phoenix_kit_warehouse` — первый потребитель этого механизма во всей экосистеме.
- `PhoenixKit.Module.migration_module/0` (см. `/www/phoenix_kit/lib/phoenix_kit/module.ex:112`, default `nil`) и генератор в `/www/phoenix_kit/lib/mix/tasks/phoenix_kit.update.ex:830-932` (`run_module_migrations/1` → `discover_module_migrations/0` → `generate_module_migration/5`) ожидают от модуля-мигратора:
  - `current_version/0 :: integer`
  - `migrated_version_runtime(prefix: prefix) :: integer` — вызывается как `migration_mod.migrated_version_runtime(prefix: prefix)` (keyword list, НЕ map).
  - `up(prefix: "...", version: N)` / `down(prefix: "...", version: N)` — сгенерированная в хосте (Andi) обёртка `priv/repo/migrations/<ts>_..._update_vN_to_vM.exs` вызывает их так же, keyword list.
  - Обёртка **не** содержит `@disable_ddl_transaction` — это надо добавить руками после генерации (PgBouncer в dev молча роняет DDL внутри транзакции — см. известную проблему проекта).
  - `PhoenixKit.Migrations.Postgres` (core, `/www/phoenix_kit/lib/phoenix_kit/migrations/postgres.ex`) — эталон стиля V-файлов (`use Ecto.Migration`, `create_if_not_exists`, `execute("COMMENT ON TABLE ... IS '<v>'")` как маркер версии), но **не наследуется** — это самостоятельный движок ядра под свою таблицу `phoenix_kit`. Для склада маркер версии должен сидеть на **своей** таблице, не на core-`phoenix_kit` (комментарий в bootstrap-миграции Andi явно говорит: `COMMENT ON TABLE phoenix_kit` — прерогатива только core). Решение: маркер версии — `COMMENT ON TABLE phoenix_kit_warehouse_stock IS '<v>'` (эта таблица гарантированно существует, раз модуль вообще работает).
- `PhoenixKitWarehouse.StockLedger.stock_map/0` и коллеги (`stock_for_items/2` + `Map.new(&{&1.item_uuid, &1})` в `goods_receipts.ex`, `goods_issues.ex`, `supplier_orders.ex`) схлопывают **все** строки `Stock` по `item_uuid`, теряя `location_uuid` — при одном складе это незаметно (одна строка на товар), но при мульти-складе это станет реальным багом (неверный "видимый" остаток, неверный `previous_quantity` в аудите приёмок/расходов, неверное посевное количество в инвентаризации). Это нужно чинить как часть задачи 1, а не откладывать.
- Обвязка документа (эталон — Internal Orders): schema (`schemas/internal_order.ex`) + context (`internal_orders.ex`, паттерн `lock_status_step` + `Ecto.Multi`) + `ColumnConfig.InternalOrders` (`use PhoenixKitWarehouse.ColumnConfig, scope: "..."`) + `Web.InternalOrderIndexLive` (`use ColumnManagement`, self-wrapped `LayoutWrapper.app_layout`) + `Web.InternalOrderFormLive` (:new/:edit/:items/:files/:comments, `use PhoenixKitComments.Embed`, `MediaBrowser.setup_uploads`, `StorageFolders.ensure_for_internal_order/2`) + `DocRefs` (label/path резолвинг) + `Web.Components.WarehouseHeader` (общий таб-бар). Все новые фичи копируют эту форму.
- «Связанные документы»: `InternalOrderFormLive` — единственный, у кого уже есть блок «upstream» (`@source_refs` через `DocRefs.refs_for/1`) **и** «downstream» (`@child_supplier_order_refs` + `@child_goods_issue_refs` через `DocRefs.supplier_order_refs_for_internal_order/1` и `goods_issue_refs_for_internal_order/1`). У `SupplierOrderFormLive`, `GoodsReceiptFormLive`, `GoodsIssueFormLive` уже есть upstream-блок (через `DocRefs.refs_for/1`), но нет downstream. У `InventoryFormLive` нет ни того, ни другого (в схеме `InventoryDocument` вообще нет `source_refs`) — это самостоятельный документ, трогать не нужно.
- Прецедента экспорта XLS/PDF **внутри** `phoenix_kit_warehouse` нет (`grep` по репозиторию — пусто). В `phoenix_kit_catalogue` есть `xlsx_reader` (только импорт) и `Export.Destination` (только **JSON и PRO100** — CSV-писателя и XLSX-записи нет). Значит по инструкции задачи — обороты в волне 1 идут **простой таблицей, без экспорта**.

## Архитектурные решения (зафиксировать, не пересматривать в ходе реализации)

- Мин. остаток — **глобальный на позицию** (не на пару позиция+склад): `available = Σ(stock по всем складам) − Σ(резерв по открытым internal orders)`. Это упрощение осознанное (см. «Открытые вопросы»).
- Перемещения — статусы `draft → in_transit → done`, плюс боковой статус `cancelled` (достижим из `draft` без проводок или из `in_transit` с реверс-проводкой — см. T11a), две раздельные атомарные проводки (`ship`: списание со склада-источника через `StockLedger.issue_quantity/3`; `receive`: зачисление на склад-приёмник через `StockLedger.receive_quantity/3`), а не одна общая транзакция — потому что физически товар уезжает и приезжает не одновременно.
- Обороты считаются **по строкам уже существующих проведённых документов** (GoodsReceipt/GoodsIssue/Transfer/InventoryDocument), т.к. отдельного ledger-журнала проводок в модуле нет. «Сальдо» в отчёте — это **текущий** остаток (из `Stock`), а не исторический остаток на конец периода (это принятое ограничение при отсутствии ledger-таблицы).
- «Складской селектор» — обычный `<select>` (см. выше), опции из нового `StockLedger.list_warehouses/0`.

---

## Часть A. Мульти-склад без миграций (§1)

### T1. StockLedger: корректная работа с несколькими складами на позицию

Файлы: `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/stock_ledger.ex`, `/www/phoenix_kit_warehouse/test/phoenix_kit_warehouse/stock_ledger_test.exs`.

Что сделать:
- Изменить `stock_map/0`: вместо `Map.new` по сырым строкам — группировать по `item_uuid` и **суммировать** `quantity` по всем `location_uuid`; `unit_value` — брать из строки с самым свежим `updated_at` среди тех, где он не `nil` (иначе `nil`). Задокументировать в `@doc` ДВЕ вещи отдельно: (a) что `quantity` — сквозная сумма по всем складам; (b) что `unit_value` в результате становится **аппроксимацией** («самый свежий по `updated_at` среди складов», а не факт по конкретному складу) — для точного значения по складу использовать `stock_map_for_location/1`.
- Добавить `stock_map_for_location(location_uuid)` — то же самое, но без агрегации (строк на пару `{item_uuid, location_uuid}` максимум одна за счёт `unique_constraint`), фильтр `where([s], s.location_uuid == ^location_uuid)`.
- Добавить `stock_for_items_at_location(item_uuids, location_uuid, target_repo \\ nil)` — аналог `stock_for_items/2`, но с фильтром по `location_uuid`, возвращает список сырых `%Stock{}` (для аудит-снапшотов при проводке — без коллапса).
- Добавить `get_quantity(item_uuid, location_uuid)` — текущий `get_quantity/1` (stock_ledger.ex:78) ищет только по `item_uuid` через `repo().get_by(Stock, item_uuid: item_uuid)`, что при мульти-складе (несколько строк `Stock` на один `item_uuid`, разных `location_uuid`) вернёт непредсказуемую строку или упадёт; новую `get_quantity/2` фильтровать по обеим колонкам (`where([s], s.item_uuid == ^item_uuid and s.location_uuid == ^location_uuid)`, `Decimal.new("0")` если строки нет) и использовать её в новых складских операциях (T11/T11a), не трогая существующие вызовы `get_quantity/1`.
- Добавить `list_warehouses/0`: `nil` если `warehouse_location_type_uuid/0` не задан, иначе `PhoenixKitLocations.Locations.list_locations(type_uuid: ...)`.

Проверка: `mix compile`; расширить `stock_ledger_test.exs` кейсом «два склада на один item_uuid» (`upsert_quantity(item, qty, location_uuid: loc_a)` + `..location_uuid: loc_b)`, проверить, что `stock_map/0` возвращает сумму, а `stock_map_for_location/1` — раздельно); `mix test test/phoenix_kit_warehouse/stock_ledger_test.exs`.

### T2. Inventories: локальная (по складу) сеедовка и аудит-снапшот вместо глобального

Файлы: `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/inventories.ex`, `test/phoenix_kit_warehouse/inventories_test.exs`.

Что сделать:
- `seed_lines/1` → `seed_lines(locale, location_uuid)`: источник строк — `StockLedger.stock_map_for_location(location_uuid)` (сейчас `StockLedger.list_stock()` без фильтра — берёт остатки со всех складов).
- `new_draft/2`: сигнатуру не менять, но теперь она уже передаёт `StockLedger.default_location_uuid()` в `seed_lines/2` (было `seed_lines(locale)`).
- `create_draft/1`: без изменений (уже принимает `location_uuid` из attrs с фоллбэком на default).
- `build_posting_multi/2` (используется `post_document/2` и `repost_document/2`): заменить `prior_stock = StockLedger.stock_map()` (снаружи, в обоих вызывающих) на `StockLedger.stock_map_for_location(doc.location_uuid)` — иначе `previous_quantity` в аудите будет суммой по всем складам, а не фактом по складу документа.
- `InventoryDocument.draft_changeset/2` сейчас `cast`ит только `[:track_value, :note, :lines, :created_by_uuid]` — БЕЗ `:location_uuid` (в отличие от `GoodsReceipt.changeset/2`/`GoodsIssue.changeset/2`, которые `:location_uuid` кастуют). Добавить `:location_uuid` в список `cast` — иначе смена склада через `update_draft/2` в T4 технически невозможна.
- Зафиксировать семантику смены `location_uuid` на уже созданном черновике: `seed_lines/2` ВСЕГДА заполняет `"counted_quantity"` у каждой строки (по факту — «системное предложение», равное текущему остатку на момент сидирования, а не признак того, что keeper физически пересчитал позицию) — отдельного флага «строка реально посчитана человеком» в схеме нет и заводить его в этой задаче не нужно (это отдельная будущая доработка). Поэтому попытка отличить «есть настоящие подсчёты» от «есть только дефолтный сид» через `nil`-проверку `counted_quantity` технически несостоятельна — на практике `doc.lines` уже непустой сразу после создания черновика (`handle_params_new/2` сидирует линии до первого сохранения). Решение: `update_draft/2` при смене `location_uuid` на новое значение — БЕЗ блокировки — всегда пересидировать `lines` через `seed_lines(doc.locale, new_location_uuid)`, замещая прежние строки целиком (старые строки относились к прежнему складу — их количества, посчитанные вручную или нет, неприменимы к новому складу в любом случае). Подтверждение «это сотрёт текущие введённые количества» — на стороне UI (T4), не в контексте. Просто «обновить `:stock_map` в сокете» (как было в исходном плане T4) недостаточно — сами строки в БД без пересидевки останутся привязаны к старому складу.

Проверка: `mix test test/phoenix_kit_warehouse/inventories_test.exs`; добавить/обновить тест «seed_lines сидит только со своего склада, не подмешивая остатки другого».

### T3. GoodsReceipts / GoodsIssues: аудит-снапшот по складу документа

Файлы: `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/goods_receipts.ex` (`apply_stock_and_post/3`), `goods_issues.ex` (`apply_stock_and_post/3`), их тесты.

Что сделать: заменить `item_uuids |> StockLedger.stock_for_items() |> Map.new(&{&1.item_uuid, &1})` на `StockLedger.stock_for_items_at_location(item_uuids, locked.location_uuid, repo) |> Map.new(&{&1.item_uuid, &1})` в обоих модулях (сам расчёт дельты через `receive_quantity`/`issue_quantity` уже и так корректно передаёт `location_uuid:` — правится только «previous_quantity» для аудита).

Проверка: `mix test test/phoenix_kit_warehouse/goods_receipts_test.exs test/phoenix_kit_warehouse/goods_issues_test.exs`.

### T4. Селектор склада в черновиках Goods Receipt / Goods Issue / Inventory

Файлы: `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/web/goods_receipt_form_live.ex`, `goods_issue_form_live.ex`, `inventory_form_live.ex` (+ их `*_test.exs`).

Что сделать (по образцу General-таба `internal_order_form_live.ex`, где сейчас `@location_name` — просто текст):
- Пока документ в `draft`, показывать `<select name="location_uuid" phx-change="set_location">`, опции — `StockLedger.list_warehouses/0`, выбранное значение — текущий `doc.location_uuid`. После `posted`/`in_transit` — как сейчас, только текст.
- `handle_event("set_location", %{"location_uuid" => uuid}, socket)` → `GoodsReceipts.update_draft/2` (или `GoodsIssues.update_draft/2`, `Inventories.update_draft/2`) с `%{location_uuid: uuid}`, обновить `:location_name` и (для Inventory) `:stock_map` в сокете.
- `InventoryFormLive`: computation `stock_map` в `mount/3` сейчас глобальный (`StockLedger.stock_map()`) и вызывается до загрузки документа — перенести пересчёт в `handle_params`/`load_*_into_socket`, использовать `StockLedger.stock_map_for_location(doc.location_uuid)` (используется для подсказки `unit_value` при ручном добавлении позиции в счётный лист). При `set_location`: показать подтверждающую модалку («Смена склада сбросит введённые количества до текущих остатков нового склада — продолжить?») ПЕРЕД вызовом `handle_event` — только после подтверждения вызвать `Inventories.update_draft/2` с новым `location_uuid` (контекст, см. T2, сам пересидит `lines` через `seed_lines/2` для нового склада, без блокировки); при успехе — перезагрузить `doc`/`stock_map`/`lines` из возвращённого документа целиком, не ограничиваться обновлением одного assign `:stock_map`.
- Internal Orders и Supplier Orders **не трогать** — по формулировке §1 селектор нужен только для приёмки/расхода/инвентаризации (эти два документа стока не двигают).

Проверка: `mix test test/phoenix_kit_warehouse/web/goods_receipt_form_live_test.exs test/phoenix_kit_warehouse/web/goods_issue_form_live_test.exs test/phoenix_kit_warehouse/web/inventory_form_live_test.exs`; вручную: `/admin/warehouse/goods-receipts/new` → General → сменить склад → Save draft → значение сохранилось.

### T5. StockLive: переключатель «По складам» / «Все склады»

Файлы: `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/web/stock_live.ex` (+ `web/stock_live_test.exs`, `web/stock_split_live_test.exs` если задевают `build_stock_items/0`).

Что сделать:
- Добавить assign `:warehouse_scope` (`nil` = все склады, иначе `location_uuid`) и control рядом с тумблером Grouped/Flat: `<select phx-change="set_warehouse_scope">` с опцией «Все склады» (value `""`) + `StockLedger.list_warehouses/0`.
- `build_stock_items/0` → принимает `warehouse_scope`; при `nil` — как сейчас через (уже исправленный в T1) `StockLedger.stock_map()`; при заданном складе — через `StockLedger.stock_map_for_location/1`. Прокинуть тот же параметр во `Flat`-пайплайн (`assign_stock_rows/1`) и в `WarehouseBrowser.stock_sheet` (Grouped).
- `handle_event("set_warehouse_scope", %{"location_uuid" => v}, socket)` — сохраняет через `ViewConfigs.merge_view_config(uuid, "warehouse_stock", %{"warehouse_scope" => v})` по аналогии с `set_stock_view`.
- Осознанно ОТЛОЖЕНО (не делать в этой задаче, зафиксировать в T22 как техдолг): индикатор/фильтр «В пути» — остатки, списанные со склада-источника через `ship_transfer`, но ещё не принятые на приёмнике (`in_transit`), сейчас нигде не отображаются ни в одном представлении Stock (ни Grouped, ни Flat) — `stock_map()`/`stock_map_for_location/1` читают только фактические строки `Stock`, минуя `Transfer.status`. Минимальная мера видимости в волне 1 — `cancel_transfer/2` (T11a), позволяющий вернуть зависший в пути товар. Полноценный индикатор — future work вне волны 1.

Проверка: `mix test test/phoenix_kit_warehouse/web/stock_live_test.exs`; вручную `/admin/warehouse` → выбрать конкретный склад → остатки/итоги пересчитались, вкладка Grouped и Flat синхронно переключились.

---

## Часть B. Инфраструктура собственных версионных миграций модуля

### T6. Верификация контракта `migration_module/0` (обязательный safety-check перед написанием кода)

Файлы: не изменяются — только чтение.

Что сделать: непосредственно перед T7 заново прочитать (могло измениться с момента написания этого плана):
- `deps/phoenix_kit/lib/mix/tasks/phoenix_kit.update.ex` внутри `/www/phoenix_kit_warehouse` (или `/www/app`, если генерация будет запускаться оттуда) — секции `run_module_migrations/1`, `discover_module_migrations/0`, `generate_module_migration/5`.
- `deps/phoenix_kit/lib/phoenix_kit/module.ex` — сигнатура `@callback migration_module() :: module() | nil`.

Подтвердить, что: (a) `migrated_version_runtime/1` вызывается с keyword list `prefix: prefix`; (b) сгенерированная обёртка вызывает `Mod.up(prefix: "...", version: N)` / `Mod.down(prefix: "...", version: N)`, тоже keyword list; (c) обёртка **не** содержит `@disable_ddl_transaction`. Если что-то разошлось с этим планом — скорректировать T7/T9/T17 до написания кода.

Проверка: заметка в PR/коммите T7 с подтверждением («сверено с исходником phoenix_kit X.Y.Z, расхождений нет» или списком расхождений и как они учтены).

### T7. `PhoenixKitWarehouse.Migrations.Postgres` + V01 (таблица `phoenix_kit_warehouse_transfers`)

Файлы (новые): `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/migrations/postgres.ex`, `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/migrations/postgres/v01.ex`. Изменить: `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse.ex`.

Что сделать:
- `PhoenixKitWarehouse.Migrations.Postgres`: `@current_version 1`; `current_version/0`; `migrated_version_runtime(opts)` (принимает keyword/enumerable, читает `prefix`, дефолт `"public"`) — запрос `pg_catalog.obj_description` по `pg_class`/`pg_namespace` для таблицы `phoenix_kit_warehouse_stock` в заданной схеме (по образцу `PhoenixKit.Migrations.Postgres.migrated_version_runtime/1`, но без retry/repo-fallback — `PhoenixKit.RepoHelper.repo()` уже используется синхронно везде в модуле); `nil`/нет комментария → `0`. `up(opts)`/`down(opts)`: конвертировать `opts` (keyword list) в map; сгенерированная host-обёртка вызывает их только с `prefix:` и `version:` (target), значения `current` она не передаёт — поэтому ПЕРВЫМ действием внутри `up/1` вычислить `current = migrated_version_runtime(prefix: prefix)` самостоятельно, затем применить диапазон по возрастанию: `target = Map.fetch!(opts, :version)`, `for v <- (current + 1)..target, do: version_module(v).up(%{prefix: prefix})` (сейчас диапазон фактически всегда `V01`, но структура сразу поддерживает будущие версии — T16 добавит V02 без изменения этого файла). `down/1` — симметрично, по убыванию от `current` до `target + 1`.
- `PhoenixKitWarehouse.Migrations.Postgres.V01`: `use Ecto.Migration`; `up(opts)`/`down(opts)` принимают map с `:prefix`. `up/1` создаёт (по образцу DDL из `20260708140000_create_phoenix_kit_warehouse_tables.exs`, тот же стиль `execute("CREATE ... IF NOT EXISTS ...")`):
  - `CREATE SEQUENCE IF NOT EXISTS <prefix>.phoenix_kit_warehouse_transfers_number_seq`
  - `CREATE TABLE IF NOT EXISTS <prefix>.phoenix_kit_warehouse_transfers` с колонками: `uuid UUID PK DEFAULT uuid_generate_v7()`, `number BIGINT NOT NULL DEFAULT nextval(...)`, `status VARCHAR(20) NOT NULL DEFAULT 'draft'`, `source_location_uuid UUID` (БЕЗ `NOT NULL` — draft-перемещение может существовать без выбранных складов, см. T10/T11: `changeset/2` не требует локации, только `ship_changeset/3` их требует — DB-констрейнт не должен быть строже changeset'а), `destination_location_uuid UUID` (аналогично, без `NOT NULL`), `note TEXT`, `storage_folder_uuid UUID`, `lines JSONB NOT NULL DEFAULT '[]'`, `source_refs JSONB NOT NULL DEFAULT '[]'`, `created_by_uuid UUID`, `performed_by_uuid UUID REFERENCES phoenix_kit_users(uuid) ON DELETE SET NULL`, `shipped_at TIMESTAMPTZ`, `received_at TIMESTAMPTZ`, `cancelled_at TIMESTAMPTZ` (для T11a — отмена перемещения), `deleted_at TIMESTAMPTZ`, `deleted_by_uuid UUID`, `timestamps`.
  - Индексы: unique на `number`; обычные на `status`, `inserted_at`, `deleted_at`, `source_location_uuid`, `destination_location_uuid`, `shipped_at`, `received_at` (в отличие от `posted_at` у уже существующих `GoodsReceipt`/`GoodsIssue`/`InventoryDocument`, который нигде не индексирован — техдолг вне охвата этой миграции, см. заметку в T20/T22; здесь таблица новая, добавить индексы сразу — дёшево).
  - `execute("COMMENT ON TABLE <prefix>.phoenix_kit_warehouse_stock IS '1'")` — маркер версии модуля (НЕ трогать core-таблицу `phoenix_kit`).
  - `down/1` — зеркально: `DROP TABLE`/`DROP SEQUENCE` для transfers, затем `COMMENT ON TABLE ... IS '0'` (или удалить комментарий).
- `phoenix_kit_warehouse.ex`: добавить `@impl PhoenixKit.Module def migration_module, do: PhoenixKitWarehouse.Migrations.Postgres`.

Проверка: `mix compile` (в `phoenix_kit_warehouse`); юнит-тест на `migrated_version_runtime/1` (0 до применения) — можно через `PhoenixKitWarehouse.DataCase`, выполнить `V01.up(%{prefix: "public"})` в тесте и проверить `current_version() == migrated_version_runtime(prefix: "public")`.

### T8. Прогон миграции в Andi и проверка на PgBouncer

Файлы: сгенерированный `/www/app/priv/repo/migrations/<ts>_..._update_v0_to_v1.exs`.

Что сделать:
1. Из `/www/app`: `mix phoenix_kit.update` (единственная команда — генерирует И применяет миграцию одним прогоном; отдельного шага «применить» нет).
2. ОЖИДАЕМЫЙ результат первого прогона в dev (не аварийный случай, а норма): `mix ecto.migrate` внутри команды запишет версию как применённую, но сама DDL (`CREATE TABLE ...`) молча провалится — PgBouncer рвёт неявную транзакцию миграции (известная проблема проекта, см. `reference_pgbouncer_migrations`). Добавить `@disable_ddl_transaction true` в файл ДО этого прогона невозможно: файла ещё не существует до генерации, а `mix phoenix_kit.update` генерирует и тут же применяет одной командой — вставить атрибут «между» негде.
3. Поэтому сразу чинить фактическое состояние БД руками через Tidewave (`mcp__tidewave__execute_sql_query` или `project_eval`) — прямые `CREATE TABLE ...`/`CREATE SEQUENCE ...`/индексы/`COMMENT ON TABLE` из V01, как в рецепте `reference_pgbouncer_migrations`.
4. Открыть уже сгенерированный файл `<ts>_..._update_v0_to_v1.exs` и добавить `@disable_ddl_transaction true` — это НЕ чинит уже прошедший прогон (БД уже починена шагом 3), а нужно для ПОСЛЕДУЮЩИХ сред (test/prod с прямым подключением к Postgres без PgBouncer, где `up`/`down` пройдут по-настоящему) и для повторных прогонов в самом dev через прямое подключение.
5. `sudo /usr/bin/supervisorctl restart elixir` (boot-time discovery `migration_module/0`/`admin_tabs/0` через beam-сканирование).

Проверка: Tidewave `execute_sql_query`: `SELECT to_regclass('public.phoenix_kit_warehouse_transfers')` — не `NULL`; `SELECT obj_description('phoenix_kit_warehouse_stock'::regclass)` = `'1'`; в IEx/Tidewave `PhoenixKitWarehouse.Migrations.Postgres.migrated_version_runtime(prefix: "public") == 1`.

---

## Часть C. Связанные документы — список-MVP (§7), общий компонент

### T9. Общий компонент «Связанные документы» + downstream-ссылки для Supplier Order

Файлы: новый `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/web/components/related_documents.ex`; изменить `doc_refs.ex`, `web/internal_order_form_live.ex`, `web/supplier_order_form_live.ex`.

Что сделать:
- `DocRefs`: добавить `goods_receipt_refs_for_supplier_order(supplier_order_uuid)` — по образцу `goods_issue_refs_for_internal_order/1`, запрос `GoodsReceipt |> where([r], r.supplier_order_uuid == ^uuid and is_nil(r.deleted_at))`.
- Новый компонент `PhoenixKitWarehouse.Web.Components.RelatedDocuments.related_documents/1` — атрибуты `upstream` (список ref-мап из `DocRefs`, с кнопкой «Attach»/`phx-click` на `open_link_picker` и «×» на `remove_source_ref`, как сейчас инлайново в `internal_order_form_live.ex`) и `downstream` (список ref-мап, только для чтения, без attach/remove). Рендерит два блока «Откуда» / «Куда» (пропускает пустые).
- `InternalOrderFormLive`: заменить существующий инлайн-блок «Imported from» + «Related documents» на вызов нового компонента (`upstream={@source_refs}`, `downstream={@child_supplier_order_refs ++ @child_goods_issue_refs}`).
- `SupplierOrderFormLive`: добавить `downstream` — новый assign `:child_goods_receipt_refs`, заполняется `DocRefs.goods_receipt_refs_for_supplier_order/1` в `load_*_into_socket`, рендерится через тот же компонент рядом с уже существующим upstream-блоком.
- `GoodsReceiptFormLive`/`GoodsIssueFormLive`/`InventoryFormLive` — не трогать (upstream уже есть своим кодом; downstream у них нет и не нужен — терминальные документы).

Проверка: `mix test test/phoenix_kit_warehouse/web/internal_order_form_live_test.exs test/phoenix_kit_warehouse/web/supplier_order_form_live_test.exs test/phoenix_kit_warehouse/doc_refs_test.exs`; вручную: открыть проведённый Supplier Order, у которого есть дочерний Goods Receipt — убедиться, что в карточке видна ссылка на него.

---

## Часть D. Перемещения (§2)

### T10. Схема `PhoenixKitWarehouse.Transfer`

Файл (новый): `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/schemas/transfer.ex`.

Что сделать: по образцу `schemas/internal_order.ex`, таблица `phoenix_kit_warehouse_transfers` (из T7), `@statuses ~w(draft in_transit done cancelled)` (`cancelled` — боковой статус, см. T11a). Поля: `number` (`read_after_writes: true`), `status`, `source_location_uuid`, `destination_location_uuid`, `note`, `storage_folder_uuid`, `lines` (`{:array, :map}`, default `[]`), `source_refs` (то же), `created_by_uuid`, `performed_by_uuid`, `shipped_at`, `received_at`, `cancelled_at`, `deleted_at`, `deleted_by_uuid`, `timestamps`.
- `changeset/2` (draft-редактирование, общие поля): `cast` всех редактируемых полей (`source_location_uuid`, `destination_location_uuid`, `note`, `lines`, `storage_folder_uuid`, `source_refs`) — БЕЗ `validate_required` на локациях. Черновик может существовать со `nil` в обоих полях (keeper ещё не выбрал склады) — это норма на стадии draft, не ошибка.
- `ship_changeset/3` (draft→in_transit, программные поля: `status`, `lines` с аудит-снапшотом, `shipped_at`, `performed_by_uuid`) — ЗДЕСЬ, а не в `changeset/2`, добавить `validate_required([:source_location_uuid, :destination_location_uuid])` + кастомную проверку `source_location_uuid != destination_location_uuid` (`validate_change/3`, ошибка на `:destination_location_uuid`): обе локации обязательны только начиная с этой стадии.
- `receive_changeset/3` (in_transit→done: `status`, `lines` с аудит-снапшотом, `received_at`, `performed_by_uuid`) — к этому моменту локации уже гарантированно заданы (прошли `ship_changeset`), но для симметрии/защиты от порчи данных можно унаследовать те же `validate_required`.
- `soft_delete_changeset/2`, `correction_changeset/2` (`note`, `storage_folder_uuid` — по образцу остальных документов), `storage_changeset/2`.
- `cancel_changeset/2` (см. T11a) — переводит в статус `cancelled` из `draft` или `in_transit`; программные поля `status`, `cancelled_at`, `performed_by_uuid`, `lines` (снэпшот реверс-проводки при отмене из `in_transit`).

Проверка: `mix compile`.

### T11. Контекст `PhoenixKitWarehouse.Transfers`

Файл (новый): `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/transfers.ex`; тест `test/phoenix_kit_warehouse/transfers_test.exs`.

Что сделать. Образец для МЕХАНИКИ ПРОВОДОК — ТОЛЬКО `goods_issues.ex`/`goods_receipts.ex` (`apply_stock_and_post/3`, откат Multi по `{:error, {:insufficient_stock, _}}`). `internal_orders.ex` сток вообще не двигает (`@moduledoc`: «They do NOT affect stock» — posting там только меняет статус и timestamps) — на него ориентируемся ТОЛЬКО за паттерном `lock_status_step`, не за механикой проводок:
- `lock_status_step(uuid, expected_status, error)` — приватная (`defp`) функция; `Transfers` заводит СВОЮ копию (как и 5 существующих контекстов — `supplier_orders.ex`, `goods_issues.ex`, `goods_receipts.ex`, `inventories.ex`, `internal_orders.ex` — каждый со своей копией, общего модуля нет; не импортировать и не выносить в этой задаче).
- `list_transfers/0`, `get_transfer!/1`, `get_transfer/1`.
- `create_transfer(attrs)` — `source_location_uuid`/`destination_location_uuid` из attrs (без дефолта на «default warehouse», т.к. это два конкретных склада — оставить `nil`, если keeper их ещё не выбрал; UI обязывает выбрать оба перед Ship).
- `update_draft/2` (только `status == "draft"`, иначе `{:error, :not_draft}`) — использует `Transfer.changeset/2` (T10), локации могут остаться `nil`.
- `ship_transfer(%Transfer{status: "draft"}, performed_by_uuid)`: СНАЧАЛА явный серверный guard — если `source_location_uuid` или `destination_location_uuid` равны `nil`, или равны друг другу, вернуть `{:error, :locations_required}` ДО входа в `Ecto.Multi` (`StockLedger.issue_quantity/3` при `location_uuid: nil` молча падает на `default_location_uuid()` — stock_ledger.ex:216 — это не то же самое, что «локация не выбрана», ошибка получилась бы тихой и неверной). Затем `Ecto.Multi` с `lock_status_step` (FOR UPDATE, ожидаемый статус `"draft"`) → для каждой строки с `transfer_quantity > 0` вызвать `StockLedger.issue_quantity(item_uuid, qty, location_uuid: source_location_uuid, repo: repo)` (при `{:error, {:insufficient_stock, _}}` — весь Multi откатывается, как в `post_goods_issue/2`) → снэпшот `previous_source_quantity` на строку → `Transfer.ship_changeset`. Возвращает `{:error, :not_draft}` для не-draft.
- `receive_transfer(%Transfer{status: "in_transit"}, performed_by_uuid)`: аналогичный guard на обе локации (на этой стадии они гарантированно уже заданы, но проверка дёшева и защищает от порчи данных вручную), `lock_status_step` на `"in_transit"`, для каждой строки — `StockLedger.receive_quantity(item_uuid, transfer_quantity, location_uuid: destination_location_uuid, repo: repo)` (аддитивно, как `post_goods_receipt/2`), снэпшот `previous_destination_quantity`, → `Transfer.receive_changeset`. `{:error, :not_in_transit}` иначе.
- `soft_delete_transfer/2` (только draft).
- `correct_transfer/2` (note/storage_folder, любой статус).
- `add_source_ref/3`, `remove_source_ref/3` — ручные ссылки через `SourceKinds` (как в `internal_orders.ex`), для upstream-блока из T9.
- `set_storage_folder/2`.
- `cancel_transfer/2` — см. отдельную задачу T11a (не эта задача).

Проверка: `mix test test/phoenix_kit_warehouse/transfers_test.exs` — как минимум кейсы: ship уменьшает сток источника; ship с недостаточным остатком откатывает весь Multi и статус остаётся draft; receive увеличивает сток приёмника и не трогает источник повторно; повторный ship/receive на уже сдвинутый документ возвращает ошибку (double-post guard); ship/receive с `nil`-локацией возвращает `{:error, :locations_required}`, а НЕ тихо проводит по default-складу.

### T11a. Отмена перемещения (`cancel_transfer/2`)

Файлы: изменить `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/schemas/transfer.ex` (T10), `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/transfers.ex` (T11), `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/activity_log.ex`; тест — новые кейсы в `test/phoenix_kit_warehouse/transfers_test.exs`.

Решение №2 шапки плана (отмена перемещения) реализуется этой задачей — без неё перемещение, отправленное в путь по ошибке, невозможно откатить иначе как ручным изменением БД.

Что сделать:
- `Transfer.cancel_changeset/2` (T10): программные поля `status: "cancelled"`, `cancelled_at`, `performed_by_uuid`; при отмене из `in_transit` дополнительно `lines` — снэпшот реверс-проводки (см. ниже), без cast пользовательских полей.
- `Transfers.cancel_transfer(%Transfer{status: "draft"} = t, performed_by_uuid)`: БЕЗ проводок (товар физически не двигался) — `lock_status_step(t.uuid, "draft", :not_cancellable)` → `Transfer.cancel_changeset` → `repo().update()`.
- `Transfers.cancel_transfer(%Transfer{status: "in_transit"} = t, performed_by_uuid)`: `Ecto.Multi` с `lock_status_step(t.uuid, "in_transit", :not_cancellable)` → для каждой строки с `transfer_quantity > 0` вызвать `StockLedger.receive_quantity(item_uuid, transfer_quantity, location_uuid: source_location_uuid, repo: repo)` — реверс: возврат на склад-источник того, что было списано при `ship_transfer` (аддитивная операция, `receive_quantity` не может провалиться по insufficient-stock) → снэпшот `reversed_source_quantity` на строку → `Transfer.cancel_changeset`.
- `cancel_transfer(%Transfer{status: status}, _performed_by_uuid)` при `status in ["done", "cancelled"]` → `{:error, :not_cancellable}` (нельзя отменить уже принятое или уже отменённое перемещение).
- `PhoenixKitWarehouse.ActivityLog`: добавить `log_transfer_cancelled(%Transfer{} = t, opts)` и новый `defp base_metadata(%Transfer{number: number})`-клоз (сейчас `base_metadata/1` типизирован только на `%InventoryDocument{}` — добавить второй clause по тому же паттерну, `action: "warehouse.transfer.cancelled"`, `resource_type: "transfer"`, `resource_uuid: t.uuid`); вызвать из `TransferFormLive` (T15) сразу после успешного `cancel_transfer/2`.

Проверка: `mix test test/phoenix_kit_warehouse/transfers_test.exs` — кейсы: cancel из draft не создаёт проводок (сток источника не менялся ни до, ни после); cancel из in_transit возвращает на источник ровно то, что было списано при ship (сток источника после cancel == сток до ship); cancel из done возвращает `{:error, :not_cancellable}`; повторный cancel уже отменённого — тоже `{:error, :not_cancellable}`; после cancel в activity log есть запись `warehouse.transfer.cancelled`.

### T12. `ColumnConfig.Transfers`

Файл (новый): `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/column_config/transfers.ex`.

Что сделать: `use PhoenixKitWarehouse.ColumnConfig, scope: "warehouse_transfers"`, колонки по образцу `column_config/internal_orders.ex`: `number`, `status` (enum-фильтр `draft`/`in_transit`/`done`/`cancelled` — 4 значения, см. T10/T11a), `date` (inserted_at), `source_location` (не sortable/filterable — резолвится в LiveView, как `sub_order` у Internal Orders), `destination_location` (то же), `lines_count`, `shipped_at`, `received_at`, `note`.

Проверка: `mix compile`.

### T13. Таб «Перемещения» в навигации

Файлы: `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse.ex`, `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/web/components/warehouse_header.ex`.

Что сделать:
- `admin_tabs/0`: новый видимый таб `:warehouse_transfers`, `path: "warehouse/transfers"`, `parent: :warehouse`, `priority: 160` (после Goods Issue=159), `live_view: {TransferIndexLive, :index}`.
- `hidden_crud_tabs/0`: `:warehouse_transfer_new` (`warehouse/transfers/new`, priority 611), `:warehouse_transfer_edit` (`warehouse/transfers/:uuid`, 612), `:warehouse_transfer_items` (`.../items`, 613), `:warehouse_transfer_files` (`.../files`, 614), `:warehouse_transfer_comments` (`.../comments`, 615) — `visible: false`, `live_view: {TransferFormLive, :new|:edit|:items|:files|:comments}`. Регистрация `:warehouse_transfer_items` здесь ОБЯЗЫВАЕТ T15 реализовать у `TransferFormLive` полноценный action `:items` (по образцу Internal Orders) — таб не должен остаться осиротевшим роутом без контента; если при реализации T15 решение изменится на «без отдельного `:items`», этот пункт `hidden_crud_tabs/0` нужно убрать синхронно.
- `WarehouseHeader`: добавить вкладку «Transfers»/«Перемещения» между Supplier Orders и Goods Receipt (порядок — на усмотрение, главное присутствие).

Проверка: `mix compile` в phoenix_kit_warehouse; из `/www/app`: recompile + `sudo /usr/bin/supervisorctl restart elixir` (boot-time discovery путь-зависимости); `AndiWeb.Router.__routes__()` через Tidewave содержит `/admin/warehouse/transfers`; открыть `/admin/warehouse/transfers` в браузере — 404 не должно быть (даже с пустым LiveView-стабом на этом этапе допустим временный редирект/пустая страница — полноценный контент появится в T14).

### T14. `Web.TransferIndexLive`

Файл (новый): `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/web/transfer_index_live.ex`; тест `web/transfer_index_live_test.exs`.

Что сделать: буквальная копия структуры `web/internal_order_index_live.ex` (self-wrapped `on_mount :self_wrapped_layout`, `use ColumnManagement column_config: ColumnConfig.Transfers, scope: "warehouse_transfers"`, поиск/сортировка/фильтры), `enrich_transfers/1` резолвит `source_location_name`/`destination_location_name` ОДНИМ батч-запросом — НЕ `get_location/1` в цикле по каждой строке списка (N+1 при росте числа перемещений): один вызов `StockLedger.list_warehouses/0` (из T1, уже отфильтрован по типу «склад», их пул мал) → `Map.new(warehouses, &{&1.uuid, &1.name})` → резолвить оба имени из этой карты в памяти для каждой строки. (Это обязательный батч, не опция — в отличие от `resolve_location_name/1` в `internal_order_form_live.ex`, который резолвит одну локацию на страницу документа и цикла не имеет вовсе.) Ссылка на карточку — `#TR-<number>`.

Проверка: `mix test test/phoenix_kit_warehouse/web/transfer_index_live_test.exs`; `/admin/warehouse/transfers` — таблица рендерится, кнопка «New transfer».

### T15. `Web.TransferFormLive` + подключение Storage/Comments

Файлы (новый): `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/web/transfer_form_live.ex` (+ тест). Изменить: `storage_folders.ex`, `comments.ex`.

Что сделать:
- `storage_folders.ex`: добавить `ensure_for_transfer(%Transfer{} = t, admin_user_uuid)` — по образцу `ensure_for_internal_order/2` (Transfer тоже без `storage_folder_uuid`-кеша в схеме? — в T10 поле `storage_folder_uuid` ЕСТЬ, значит использовать полный `ensure_cached`/`create_and_cache` паттерн, как у Goods Receipt/Issue, с `&Transfers.set_storage_folder/2`, префикс имени папки `"transfer"`).
- `comments.ex`: добавить `transfer: "transfer"` в `@resource_types`, `:transfer` в тип `kind()`.
- `TransferFormLive`: копия структуры `internal_order_form_live.ex`, отличия:
  - Actions `:new`/`:edit`/`:items`/`:files`/`:comments` — как у `InternalOrderFormLive` (это обязательно: T13 регистрирует таб `:warehouse_transfer_items`, который требует реально реализованного action `:items`, иначе роут осиротеет). General-таб (`:new`/`:edit`) — шапка документа (статус, локации, note); отдельный action `:items` — редактор строк перемещения (таблица lines).
  - Два `<select>` (source/destination) вместо одного `location_uuid` на General-табе, редактируемые только в draft; после ship — источник read-only текст, после receive — оба read-only.
  - Lines editor (action `:items`): поле `transfer_quantity` вместо `required_quantity`; после `in_transit` — read-only (товар уже физически уехал).
  - Кнопки действий: `draft` → «Ship» (`handle_event("ship", ...)`: `ensure_saved` (сохранить lines/note через `update_draft`) → `Transfers.ship_transfer/2`) и «Cancel» (`handle_event("cancel", ...)`: `Transfers.cancel_transfer/2` из `draft` — без проводок, см. T11a); `in_transit` → «Receive» (`handle_event("receive", ...)`: `Transfers.receive_transfer/2` напрямую, lines уже неизменяемы) и «Cancel» (тот же `handle_event("cancel", ...)`, но из `in_transit` контекст выполняет реверс-проводку, см. T11a; кнопка требует подтверждения — модалка, т.к. это реверс уже состоявшегося движения стока); `done`/`cancelled` → бейдж статуса, только `save_correction` (note) для админа, кнопки Ship/Receive/Cancel скрыты. После успешного `cancel_transfer/2` вызвать `ActivityLog.log_transfer_cancelled/2` (T11a).
  - `RelatedDocuments` (из T9): `upstream={@source_refs}` (ручные ссылки через `open_link_picker`/`SourceKinds`, без импорта строк — Transfers не тянут строки из внешних источников), `downstream={[]}`.
  - Files/Comments табы — идентичны Internal Order (используют `ensure_for_transfer/2`, `Comments`/`CommentsPanel` c `kind: :transfer`).

Проверка: `mix test test/phoenix_kit_warehouse/web/transfer_form_live_test.exs`; вручную: `/admin/warehouse/transfers/new` → выбрать 2 разных склада → добавить позицию с остатком на источнике → Ship → сток источника уменьшился (проверить на `/admin/warehouse` с фильтром по складу-источнику) → Receive → сток приёмника увеличился; отдельно: создать второй transfer, Ship, затем «Cancel» → сток источника вернулся к значению до Ship.

---

## Часть E. Контроль дефицита, полный вариант (§5)

### T16. Verify + V02 (таблица `phoenix_kit_warehouse_min_stock`)

Файлы (новый): `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/migrations/postgres/v02.ex`. Изменить: `migrations/postgres.ex` (`@current_version 2`, добавить V02 в диапазон `up/1`/`down/1` — уже подготовлено в T7 как цикл по диапазону, менять не нужно, если T7 сделан универсально).

Что сделать (повторно — короткая версия T6/T7/T8, второй прогон механизма):
- `V02.up/1`: `CREATE TABLE IF NOT EXISTS <prefix>.phoenix_kit_warehouse_min_stock (uuid UUID PK DEFAULT uuid_generate_v7(), item_uuid UUID NOT NULL, min_quantity NUMERIC NOT NULL DEFAULT 0, timestamps)`; `CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_warehouse_min_stock_item_uuid_index ON ... (item_uuid)`; `COMMENT ON TABLE phoenix_kit_warehouse_stock IS '2'`.
- `V02.down/1` — зеркально, `COMMENT ... IS '1'`.
- Из `/www/app`: `mix phoenix_kit.update` (ОЖИДАЕМО первый прогон в dev молча уронит DDL под PgBouncer, версия запишется, а таблица не создастся — это норма, не авария, см. полный рецепт в T8) → сразу починить руками через Tidewave прямыми `CREATE TABLE`/`CREATE UNIQUE INDEX`/`COMMENT ON TABLE` из V02 → добавить `@disable_ddl_transaction true` в сгенерированный `..._update_v1_to_v2.exs` (для последующих сред, см. T8 п.4 — не чинит уже прошедший прогон) → `sudo supervisorctl restart elixir`.

Проверка: Tidewave `SELECT to_regclass('public.phoenix_kit_warehouse_min_stock')` не `NULL`; `PhoenixKitWarehouse.Migrations.Postgres.current_version() == 2 == migrated_version_runtime(prefix: "public")`.

### T17. Схема + контекст `MinStock`

Файлы (новые): `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/schemas/min_stock.ex` (`PhoenixKitWarehouse.MinStock`), `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/min_stock_settings.ex` (`PhoenixKitWarehouse.MinStockSettings`), тест `test/phoenix_kit_warehouse/min_stock_settings_test.exs`.

Что сделать: схема — `item_uuid` (уникальный), `min_quantity` (`:decimal`, default `Decimal.new("0")`), `timestamps`. Контекст: `get_min_quantity(item_uuid)` (Decimal, `0` если нет строки), `set_min_quantity(item_uuid, qty)` (upsert по `item_uuid`, `on_conflict: {:replace, [:min_quantity, :updated_at]}`), `min_stock_map/0` (`%{item_uuid => Decimal}`, только строки с `min_quantity > 0` — нулевые не считаются «настроен минимум»), `delete_min_quantity(item_uuid)`.

Проверка: `mix test test/phoenix_kit_warehouse/min_stock_settings_test.exs`.

### T18. Контекст `Deficits`

Файл (новый): `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/deficits.ex`, тест `test/phoenix_kit_warehouse/deficits_test.exs`.

Что сделать:
- `reserved_by_item/0`: источник — `InternalOrders.list_posted_internal_orders/0` (уже отфильтрован в SQL по `status == "posted"` — draft-заказы НЕ резервируют сток, иначе получаются ложные дефициты от ещё не подтверждённых заявок). Собрать `io_uuids`, вызвать `committed = CommittedQuantities.compute(GoodsIssue, ["internal_order"], io_uuids, "issued_quantity")` — результат ВЛОЖЕННАЯ карта `%{io_uuid => %{item_uuid => Decimal}}` (уже отгруженное по каждой строке каждого IO), НЕ плоская сумма по товару. Для каждого posted `io` и каждой его строки: `already_issued = get_in(committed, [io.uuid, line["item_uuid"]]) || Decimal.new("0")`; `reserved_line = Decimal.max(Decimal.new("0"), Decimal.sub(parse_decimal(line["required_quantity"]), already_issued))` — эта разница считается **по строке каждого IO отдельно**, а не глобальной суммой «Σ required минус Σ issued по товару» (иначе отгрузка по одному IO неверно «погасит» резерв другого IO на тот же товар). Просуммировать `reserved_line` по `item_uuid` через все IO/строки → `%{item_uuid => Decimal}`. (Переиспользует существующий `CommittedQuantities` — ничего нового туда не добавлять.)
- `available_by_item/0`: `%{item_uuid => Decimal}` = `StockLedger.stock_map()` (сумма по всем складам, из T1) минус `reserved_by_item/0`, по каждому item_uuid из объединения обоих ключей (отсутствующий в одном из них трактуется как `0`). Ограничение волны 1: не видит товар «в пути» по незавершённым (`in_transit`) перемещениям — см. заметку о видимости в T5/T20; не компенсировать это в рамках T18.
- `list_deficits/0`: для каждой строки `MinStockSettings.min_stock_map/0` (только настроенные >0) — `available = available_by_item()[item_uuid] || 0`; если `available < min_quantity` — включить в результат `%{item_uuid:, min_quantity:, available:, deficit: min_quantity - available}`.

Проверка: `mix test test/phoenix_kit_warehouse/deficits_test.exs` — кейсы: остаток 10, ПРОВЕДЁННЫЙ (posted) IO на 4, из них 1 уже отгружен через GoodsIssue → reserved=3 → available=7; min_quantity=8 → дефицит=1. Отдельный кейс: остаток 10, DRAFT IO на 4 (не posted) → reserved=0 (черновик не резервирует) → available=10. Отдельный кейс: два разных posted IO с одинаковым item_uuid → резерв считается по строке каждого IO независимо и корректно суммируется (не глобальным вычитанием).

### T19. Stock-таблица: Min/Available/Deficit + фильтр «ниже минимума» + переход в заказ поставщику

Файлы: `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/web/stock_live.ex`, `column_config/stock.ex`.

Что сделать:
- `ColumnConfig.Stock`: добавить колонки `min_quantity` (не sortable по значению из БД напрямую нужен — sort_key на числовое поле есть), `available` (numeric_range filter), `deficit?` (enum-фильтр «Да/Нет», через `enum_filter`).
- `StockLive.enrich_stock/2`: подмешать `min_quantity`/`available`/`below_min?` из `Deficits`/`MinStockSettings` (один вызов `Deficits.available_by_item/0` + `MinStockSettings.min_stock_map/0` на весь список, не в цикле — избежать N+1).
- Рендер `min_quantity` в Flat-таблице — инлайн-редактируемое поле по паттерну реального образца в `internal_order_form_live.ex:1342-1357`: `phx-change` (НЕ голый `phx-blur`) + `phx-debounce="blur"` + `phx-hook="InvEnterBlur"` (`<input type="number" phx-change="set_min_quantity" phx-debounce="blur" phx-hook="InvEnterBlur" phx-value-item={entry.item.uuid}>`), `handle_event("set_min_quantity", ...)` → `MinStockSettings.set_min_quantity/2` → `assign_stock_rows/1`.
- Строки с `below_min?` — визуальный бейдж/подсветка строки (`class` с `text-error`/`badge-error`), плюс в Grouped-виде (`WarehouseBrowser.stock_sheet`) — лёгкий индикатор (иконка) на позиции; полноценные inline-edit/filter — только во Flat (согласно решению «доступно/deficit — сквозные по всем складам», см. заметку в архитектурных решениях).
- Кнопка на строке-дефиците «Создать заказ поставщику» → `handle_event("create_supplier_order_from_deficit", %{"item_uuid" => uuid}, socket)`: перед кодом прочитать `SupplierOrder.changeset/2` (`supplier_order.ex:43` — `validate_required([:location_uuid])`, поле обязательное) и приватную `build_enriched_line/4` в `supplier_orders.ex` (строка = 10 ключей: `item_uuid`, `name`, `sku`, `unit`, `catalogue_uuid`, `required_quantity`, `on_hand_quantity`, `shortfall_quantity`, `ordered_quantity`, `base_price`; `name`/`sku`/`unit`/`base_price` тянуть через `PhoenixKitCatalogue.Catalogue.list_items_by_uuids/1`, не набирать руками). Вызвать `SupplierOrders.create_supplier_order/1` с явным `location_uuid: StockLedger.default_location_uuid()` (у `create_supplier_order/1` и так есть внутренний фоллбэк на дефолтный склад при отсутствующем `location_uuid` — передавать явно для читаемости и на случай будущего изменения дефолта), одна строка в `lines` с этими 10 ключами (`ordered_quantity`/`required_quantity`: `deficit_qty`; `on_hand_quantity`/`shortfall_quantity` — из уже вычисленных `Deficits`-значений `available`/`deficit`), `supplier_uuid: nil` (keeper выбирает вручную), `push_navigate` на `/admin/warehouse/supplier-orders/<uuid>`.

Проверка: `mix test test/phoenix_kit_warehouse/web/stock_live_test.exs`; вручную: задать min для позиции с текущим остатком ниже минимума → строка подсвечена, фильтр «Deficit» её показывает → «Создать заказ поставщику» → редирект на новый SO-черновик с этой строкой.

---

## Часть F. Обороты (§8, без экспорта)

### T20. Контекст `Turnover`

Файл (новый): `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/turnover.ex`, тест `test/phoenix_kit_warehouse/turnover_test.exs`.

Что сделать: `compute(location_uuid_or_nil, date_from, date_to)` → список `%{item_uuid:, name:, sku:, unit:, inflow: Decimal, outflow: Decimal, balance: Decimal}`:
- Приход: Σ `GoodsReceipt` (posted, `posted_at` в `[date_from, date_to]`, при заданном `location_uuid` — фильтр `receipt.location_uuid`) `.lines[]."received_quantity"`; + Σ `Transfer` (`received_at` в диапазоне, `destination_location_uuid == location_uuid` если задан) `.lines[]."transfer_quantity"`; + положительная часть дельты `InventoryDocument` (posted, `posted_at` в диапазоне, `doc.location_uuid` фильтр) `counted_quantity - previous_quantity` где `> 0`.
- Расход: Σ `GoodsIssue` (`posted_at` в диапазоне, `location_uuid` фильтр) `.lines[]."issued_quantity"`; + Σ `Transfer` (`shipped_at` в диапазоне, `source_location_uuid == location_uuid` если задан) `.lines[]."transfer_quantity"`; + `abs()` отрицательной части дельты `InventoryDocument`.
- `balance`: текущий остаток — `StockLedger.stock_map()[item_uuid]` (все склады) либо `StockLedger.stock_map_for_location(location_uuid)[item_uuid]` при заданном складе. Явно задокументировать в `@moduledoc`, что это остаток «сейчас» (текущий факт из `Stock`), а НЕ историческое сальдо на конец периода `date_to` — ledger-журнала проводок, из которого можно восстановить остаток на произвольную дату в прошлом, в модуле нет; это принятое ограничение волны 1 (это же пояснение продублировать в UI — см. T21). Дополнительно: `balance` не видит товар «в пути» по незавершённым (`in_transit`) перемещениям (то же ограничение, что и у `Deficits.available_by_item/0` в T18) — не пытаться это компенсировать в T20.
- Технический долг по индексам: `posted_at` у `GoodsReceipt`/`GoodsIssue`/`InventoryDocument` нигде не индексирован (уже существующие core-таблицы, миграция на них вне охвата этого плана) — при росте объёма документов фильтрация `compute/3` по диапазону дат станет медленной; зафиксировать как техдолг в T22 (`DEVELOPMENT_PLAN.md`), не чинить в волне 1. Для НОВОЙ таблицы `phoenix_kit_warehouse_transfers` индексы на `shipped_at`/`received_at` добавлены сразу в T7/V01 — это дёшево, раз таблица новая.
- Группировка результата по `item_uuid`, обогащение именем/SKU/unit через `PhoenixKitCatalogue.Catalogue.list_items_by_uuids/1` (как в `stock_live.ex`).

Проверка: `mix test test/phoenix_kit_warehouse/turnover_test.exs` — кейс: приёмка 10 в периоде, расход 3 в периоде, инвентаризационная коррекция −1 в периоде → `inflow=10, outflow=4`.

### T21. `Web.TurnoverReportLive`

Файлы (новые): `/www/phoenix_kit_warehouse/lib/phoenix_kit_warehouse/web/turnover_report_live.ex` (+ тест). Изменить: `phoenix_kit_warehouse.ex` (таб), `warehouse_header.ex`.

Что сделать:
- LiveView без `ColumnManagement`/`ColumnConfig` (простая таблица с фиксированными колонками — сознательно не используем table-parity стек, отчёт не нуждается в персонализации колонок): self-wrapped `LayoutWrapper.app_layout`, форма с `date_from`/`date_to` (`phx-change`, дефолт — текущий месяц) + `<select>` склада (опция «Все склады» + `StockLedger.list_warehouses/0`), таблица `Turnover.compute/3`.
- В шапке колонки «Сальдо»/`balance` — короткая поясняющая подпись/tooltip: «текущий остаток на данный момент, не историческое сальдо на конец периода» (то же ограничение, что задокументировано в `@moduledoc` T20 — должно быть видно keeper'у в UI, а не только в коде).
- `admin_tabs/0`: новый видимый таб `:warehouse_turnover`, `path: "warehouse/turnover"`, `parent: :warehouse`, `priority: 161`, `live_view: {TurnoverReportLive, :index}`.
- `WarehouseHeader`: добавить вкладку «Turnover»/«Обороты».
- Явно **не** добавлять кнопку экспорта — прецедента XLS-записи в модуле нет (см. «Текущее состояние»); при необходимости — отдельная будущая задача.

Проверка: `mix compile` phoenix_kit_warehouse → из `/www/app` recompile + `sudo supervisorctl restart elixir` → `/admin/warehouse/turnover` открывается, таблица считается по умолчанным датам; `mix test test/phoenix_kit_warehouse/web/turnover_report_live_test.exs`.

---

## Финал

### T22. Обновить `dev_docs/DEVELOPMENT_PLAN.md`

Файл: `/www/phoenix_kit_warehouse/dev_docs/DEVELOPMENT_PLAN.md`.

Что сделать: отметить в §9/§10-а, что пункты 1 (мульти-склад), 2 (перемещения, включая отмену), 5 (контроль дефицита), 8-обороты (без экспорта), 7-список-MVP реализованы волной 1; зафиксировать принятые упрощения и техдолг как заметки для будущих итераций:
- min_stock — глобальный на позицию, а не на пару позиция+склад;
- обороты — «сальдо» текущее, не историческое (нет ledger-журнала);
- `available`/`balance` не видят товар «в пути» по незавершённым перемещениям (минимальная мера — `cancel_transfer/2`); полноценный индикатор «В пути» в StockLive — отложен (см. T5);
- `posted_at` не индексирован у `GoodsReceipt`/`GoodsIssue`/`InventoryDocument` (существующие core-таблицы) — см. T20;
- `unit_value` в `StockLedger.stock_map/0` — аппроксимация («самый свежий по `updated_at`» среди складов), не факт по конкретному складу — см. T1;
- селектор склада в формах InternalOrder/SupplierOrder отложен на волну 2 (см. решение №5 оркестратора в шапке плана);
- замена `<select>` на `PlacePicker` из locations v0.5 — T23, опционально, по готовности locations.

Проверка: файл читается, дата/раздел актуальны — ревью-чек, без автоматической проверки.

### T23. (опционально, хвост волны 1) Заменить `<select>` склада на `PlacePicker`

Файлы: все места, где в волне 1 использован `<select>` для выбора склада — `goods_receipt_form_live.ex`, `goods_issue_form_live.ex`, `inventory_form_live.ex` (T4), `stock_live.ex` (T5), `transfer_form_live.ex` (T15), `turnover_report_live.ex` (T21).

Условие выполнения: `phoenix_kit_locations` опубликовал `PlacePicker` LiveComponent (контракт из шапки плана: `{:place_picker_select, id, %{location_uuid, space_uuid}}`) и `PhoenixKitLocations.Spaces.full_path/2`. Если к моменту начала волны 1 этого ещё нет — задача НЕ выполняется, целиком откладывается в волну 2 (не блокирует остальной план — везде уже есть текстовый/select-fallback, см. «Текущее состояние»).

Что сделать (когда готово): заменить каждый `<select phx-change="set_...">` на `<.live_component module={PlacePicker} id=... />`; обработать `{:place_picker_select, id, %{location_uuid: uuid}}` в `handle_info/2` вместо текущего `handle_event("set_...", ...)`; там, где сейчас read-only имя склада рендерится простым текстом — заменить на `Spaces.full_path/2`, если он к тому моменту возвращает иерархический путь (склад → зона → полка), а не просто имя.

Проверка: `mix test` по всем затронутым LiveView-тестам (обновить моки/assertions под новый компонент); вручную повторить те же ручные проверки, что были в T4/T5/T15/T21, но уже через picker вместо select.

---

## Общие правила для каждой задачи

- `mix format && mix quality` (или хотя бы `mix format && mix credo --strict`) перед коммитом в `phoenix_kit_warehouse`.
- После любого изменения в `phoenix_kit_warehouse.ex` (`admin_tabs/0`, `migration_module/0`) — из `/www/app`: recompile + `sudo /usr/bin/supervisorctl restart elixir` (path-dep, boot-time, без hot-reload — см. окружение). Рутинные правки LiveView/контекстов внутри уже зарегистрированных модулей — без рестарта.
- Миграции — только через `mix phoenix_kit.update` из `/www/app`; каждую сгенерированную обёртку проверять на `@disable_ddl_transaction` (PgBouncer).
- Не трогать `CHANGELOG.md`/`@version` — это прерогатива мейнтейнера.
- Коммиты — в `main` `phoenix_kit_warehouse`, без AI-атрибуции.
