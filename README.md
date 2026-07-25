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
`UPalGameSetting` instance:

- `WorkerCollectResourceStackMaxNum`
- `WorkTransportingDelayTimeDropItem`
- `WorkTransportingSpeedRate`
- `WorkTransportingItemNumRateInShouldTeleportWorker`
- `BaseCampWorkerDistancePickableItem`
- `DropItemWaitInsertMaxNumPerTick`
- `MergeDropItemRange`
- `WorkSuitabilityMaxRank`

Only the values are logged. The `UPalGameSetting` object is not retained.

### Timeline events

- `ASSIGN_PRE` / `ASSIGN_POST`: transport work assignment and native-call time
- `ACTION_BLACKBOARD`: transported item selected by the transport action
- `ACTION_SETUP`: carried-item actor setup begins
- `ITEM_MOVE`: an item-container move matched to the active worker
- `CONTAINER_UPDATE`: the transport director received a container update
- `UNASSIGN`: transport assignment ended
- `SUMMARY`: throttled event counters

Worker correlation uses a string made from `FPalInstanceID.InstanceId`. The
bounded state cache contains strings, numbers, and timestamps only. It does not
retain worker, action, work, container, or other UObject references.

### Installation and test

1. Copy `PalTransportTimingProbe` into the server's `ue4ss/Mods` directory.
2. Restart the dedicated server.
3. Confirm `[PalTransportTimingProbe] [STARTED]` and six `HOOK_OK` lines.
4. Let several Pals pick up and store items for one or two minutes.
5. Save the server `UE4SS.log` for analysis.
6. Disable or remove the probe after the measurement run.

Logging can be reduced in `Scripts/config.lua`. Changes require a server
restart.

## 日本語

`PalTransportTimingProbe`は、Palworld専用サーバー用の読み取り専用UE4SS
Lua診断MODです。`EnhancedBaseLogistics`を変更する前に、取得と収納の待ち時間を
計測できるよう、サーバー側の運搬ライフサイクルを記録します。

このProbeはゲーム設定、アイテム数、コンテナ、作業パル、セーブデータを変更しません。

### 観測する設定値

起動時に、有効な`UPalGameSetting`インスタンスから次の値を読み取ってログへ出します。

- `WorkerCollectResourceStackMaxNum`
- `WorkTransportingDelayTimeDropItem`
- `WorkTransportingSpeedRate`
- `WorkTransportingItemNumRateInShouldTeleportWorker`
- `BaseCampWorkerDistancePickableItem`
- `DropItemWaitInsertMaxNumPerTick`
- `MergeDropItemRange`
- `WorkSuitabilityMaxRank`

ログに出すのは値だけです。`UPalGameSetting`オブジェクトは保持しません。

### 時系列イベント

- `ASSIGN_PRE` / `ASSIGN_POST`：運搬作業の割り当てとネイティブ呼び出し時間
- `ACTION_BLACKBOARD`：運搬アクションが対象アイテムを選択
- `ACTION_SETUP`：持ち運ぶアイテムActorの準備開始
- `ITEM_MOVE`：作業パルと対応したアイテムコンテナ移動
- `CONTAINER_UPDATE`：運搬Directorがコンテナ更新を受信
- `UNASSIGN`：運搬割り当て終了
- `SUMMARY`：間引いたイベント集計

作業パルの対応付けには`FPalInstanceID.InstanceId`から作った文字列を使用します。
上限付き状態キャッシュに保持するのは文字列、数値、時刻だけです。作業パル、
アクション、作業、コンテナなどのUObject参照は保持しません。

### 導入とテスト

1. `PalTransportTimingProbe`をサーバーの`ue4ss/Mods`へコピーします。
2. 専用サーバーを再起動します。
3. `[PalTransportTimingProbe] [STARTED]`と6行の`HOOK_OK`を確認します。
4. 複数のパルに1～2分ほどアイテムの取得と収納を行わせます。
5. サーバーの`UE4SS.log`を保存して解析します。
6. 計測終了後はProbeを無効化または削除します。

ログ量は`Scripts/config.lua`で減らせます。変更後はサーバー再起動が必要です。
