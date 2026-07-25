# PalTransportTimingProbe

## English

`PalTransportTimingProbe` is a read-only UE4SS Lua diagnostic mod for a
Palworld dedicated server. It records the server-side transport lifecycle so
pickup and storage delays can be measured before changing
`EnhancedBaseLogistics`.

The probe does not change game settings, item counts, containers, workers, or
save data.

### Observed settings

At startup the probe reads and logs these values from the active
`UPalGameSetting` instance. It then reacquires the active instance every
`GameSettingsPollIntervalMs` milliseconds (10 seconds by default) and emits
`SETTINGS_CHANGED` only when one or more values differ:

- `WorkerCollectResourceStackMaxNum`
- `WorkTransportingDelayTimeDropItem`
- `WorkTransportingSpeedRate`
- `WorkTransportingItemNumRateInShouldTeleportWorker`
- `BaseCampWorkerDistancePickableItem`
- `DropItemWaitInsertMaxNumPerTick`
- `MergeDropItemRange`
- `WorkSuitabilityMaxRank`

Only scalar values are retained for comparison. The `UPalGameSetting` object
is not retained between samples.

### Timeline events

- `ASSIGN_PRE` / `ASSIGN_POST`: transport-target assignment and native-call time
- `REQUIREMENT_ASSIGN_PRE` / `REQUIREMENT_ASSIGN_POST`: transport-requirement
  assignment and native-call time
- `ITEM_MOVE`: the concrete server-side item-container move matched to an
  active worker
- `CONTAINER_UPDATE`: the transport director received a container update
- `UNASSIGN`: transport-target assignment ended
- `REQUIREMENT_UNASSIGN`: transport-requirement assignment ended
- `SUMMARY`: throttled event counters

Each assignment records `UPalWorkTransportItemInBaseCamp.TransportType` as
both its numeric value and phase name:

- `0`: `TakeOut`
- `1`: `PutIn`

This allows pickup-side and storage-side durations to be analyzed separately.
Item moves are observed through
`UPalEventNotify_ItemContainer:OnItemOperationMove_ServerInternal`, rather
than the delegate-signature function that did not fire on the dedicated
server.

Worker correlation uses a string made from `FPalInstanceID.InstanceId`. The
bounded state cache contains strings, numbers, and timestamps only. It does not
retain worker, work, container, game-setting, or other UObject references.

### Installation and test

1. Copy `PalTransportTimingProbe` into the server's `ue4ss/Mods` directory.
2. Restart the dedicated server.
3. Confirm `[PalTransportTimingProbe] [STARTED]` and six `HOOK_OK` lines.
4. Let several Pals pick up and store items for one or two minutes.
5. Save the server `UE4SS.log` for analysis.
6. Disable or remove the probe after the measurement run.

Logging can be reduced in `Scripts/config.lua`. Changes require a server
restart. Set `GameSettingsPollIntervalMs` to `0` to disable periodic setting
checks while retaining the startup sample.

## 日本語

`PalTransportTimingProbe`は、Palworld専用サーバー用の読み取り専用UE4SS
Lua診断MODです。`EnhancedBaseLogistics`を変更する前に、取得と収納の待ち時間を
計測できるよう、サーバー側の運搬ライフサイクルを記録します。

このProbeはゲーム設定、アイテム数、コンテナ、作業パル、セーブデータを変更しません。

### 観測する設定値

起動時に、有効な`UPalGameSetting`インスタンスから次の値を読み取ってログへ出します。
その後は`GameSettingsPollIntervalMs`ミリ秒ごと（既定10秒）に有効なインスタンスを
再取得し、1つ以上の値が変化した場合だけ`SETTINGS_CHANGED`を出力します。

- `WorkerCollectResourceStackMaxNum`
- `WorkTransportingDelayTimeDropItem`
- `WorkTransportingSpeedRate`
- `WorkTransportingItemNumRateInShouldTeleportWorker`
- `BaseCampWorkerDistancePickableItem`
- `DropItemWaitInsertMaxNumPerTick`
- `MergeDropItemRange`
- `WorkSuitabilityMaxRank`

比較用に保持するのはスカラー値だけです。サンプル間で`UPalGameSetting`
オブジェクトは保持しません。

### 時系列イベント

- `ASSIGN_PRE` / `ASSIGN_POST`：運搬対象の割り当てとネイティブ呼び出し時間
- `REQUIREMENT_ASSIGN_PRE` / `REQUIREMENT_ASSIGN_POST`：運搬Requirementの
  割り当てとネイティブ呼び出し時間
- `ITEM_MOVE`：作業パルと対応した、サーバー実処理上のアイテムコンテナ移動
- `CONTAINER_UPDATE`：運搬Directorがコンテナ更新を受信
- `UNASSIGN`：運搬対象の割り当て終了
- `REQUIREMENT_UNASSIGN`：運搬Requirementの割り当て終了
- `SUMMARY`：間引いたイベント集計

各割り当てでは`UPalWorkTransportItemInBaseCamp.TransportType`を数値と
フェーズ名の両方で記録します。

- `0`：`TakeOut`
- `1`：`PutIn`

これにより、取得側と収納側の所要時間を分けて解析できます。
アイテム移動は、専用サーバーで発火しなかったDelegate Signatureではなく、
`UPalEventNotify_ItemContainer:OnItemOperationMove_ServerInternal`で観測します。

作業パルの対応付けには`FPalInstanceID.InstanceId`から作った文字列を使用します。
上限付き状態キャッシュに保持するのは文字列、数値、時刻だけです。作業パル、
作業、コンテナ、ゲーム設定などのUObject参照は保持しません。

### 導入とテスト

1. `PalTransportTimingProbe`をサーバーの`ue4ss/Mods`へコピーします。
2. 専用サーバーを再起動します。
3. `[PalTransportTimingProbe] [STARTED]`と6行の`HOOK_OK`を確認します。
4. 複数のパルに1～2分ほどアイテムの取得と収納を行わせます。
5. サーバーの`UE4SS.log`を保存して解析します。
6. 計測終了後はProbeを無効化または削除します。

ログ量は`Scripts/config.lua`で減らせます。変更後はサーバー再起動が必要です。
`GameSettingsPollIntervalMs`を`0`にすると、起動時の取得を残したまま定期確認を
無効化できます。
