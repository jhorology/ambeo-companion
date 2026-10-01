# コードレビューと修正対応（2026-10-01）

## 対象と確認方法

リポジトリのアプリ本体、AmbeoCore、実験用ターゲット、ビルド・インストールスクリプトを確認した。指摘はコード上の処理経路に基づくもので、レビュー時点では実機での再現確認は行っていない。

レビュー後に以下の4件を修正し、自動テストと `http://ambeo.local` への接続で検証した。検証方法・結果・実機で未確認の範囲は [検証記録](VALIDATION.md) を参照。

## 1. Atmos 再生中にもステレオへ強制変更される

**優先度：高／修正実装済み**

### 指摘

`applyFallbackFormatIfNeeded` は現在のフォーマットが Atmos／マルチチャンネルかを判定していなかった。起動時、出力デバイス変更時、「Wake Up Soundbar」実行時にも呼ばれるため、再生中の Atmos フォーマットを設定済みのステレオ形式へ上書きする可能性があった。

### 修正対応

現在の物理フォーマットを取得でき、Atmos／マルチチャンネルではなく、指定フォーマットと異なる場合にだけ Fallback を適用する。フォーマットを取得できない場合も適用を見送る。

- 変更箇所：[AppModel.swift](../Sources/AmbeoCompanion/App/AppModel.swift) の `applyFallbackFormatIfNeeded`
- 確認：cc+3、8ch PCM、2ch PCM の判定テストが成功。Atmos 再生中の実機でのフォーマット維持は未確認。

## 2. 初回の通信失敗で音量キーが復旧しなくなる

**優先度：高／修正実装済み**

### 指摘

初回取得に失敗してもエンドポイントは登録済みになり、通常のポーリングで音量値を取得できても、操作情報を持つ `stateCache` は補完されなかった。音量キーと Atmos Boost は `getEntry` を取得できないと処理を終了するため、通信復旧後も操作できない状態が続く経路があった。

### 修正対応

`getEntry` を非同期にし、キャッシュがない場合は実機から再取得する。取得値を状態にも反映する。再取得は単一オブジェクトと配列の両方に対応する。`getValue` も非同期の取得処理に合わせた。

- 変更箇所：[AmbeoClient.swift](../Sources/AmbeoCore/Network/AmbeoClient.swift) の `getEntry`、`getValue`、`fetchDirectValue`
- 確認：単一／配列レスポンスの復旧テストが成功。初回だけ通信エラーを注入した後、実機から音量と min/max/step を取得できた。

## 3. アプリ終了時に Atmos Boost が残る

**優先度：中／修正実装済み**

### 指摘

終了時は設定保存のみで、適用中のブーストを解除していなかった。例えば音量30に20を加えた状態で終了すると本体は50のままになる。再起動時に適用量の記録が0に戻るため、Atmos 再生中ならさらに20を加えて70になる経路があった。

### 修正対応

アプリケーションデリゲートの `applicationShouldTerminate` が `.terminateLater` を返し、`prepareForTermination` の完了後に終了を許可する。終了開始後の追加ブースト操作を抑止し、進行中の処理を待ってから、実機の最新音量を使って解除する。

機器ごとの適用量を UserDefaults に保存し、解除できなかった場合は記録を保持する。再起動後も記録を読み込み、同じ機器への二重加算を防ぐ。

- 変更箇所：[AmbeoCompanionApp.swift](../Sources/AmbeoCompanion/App/AmbeoCompanionApp.swift) の `CompanionAppDelegate`、[AppModel.swift](../Sources/AmbeoCompanion/App/AppModel.swift) の終了・ブースト処理
- 共通処理：[AmbeoClient.swift](../Sources/AmbeoCore/Network/AmbeoClient.swift) の `removeVolumeBoost`、[AtmosBoostLedger.swift](../Sources/AmbeoCore/Audio/AtmosBoostLedger.swift)
- 確認：記録の再読み込み、最新音量による解除、音量下限の保護を自動テストで確認。解除処理は実機でも成功。ブースト適用中の GUI アプリ終了／再起動は未確認。

## 4. 別のサウンドバーへブースト量を引き継ぐ

**優先度：中／修正実装済み**

### 指摘

再接続時に保持する `appliedAtmosBoost` は、別のサウンドバーを選んだ場合にも引き継がれていた。Aに20を加えた状態でステレオ再生中のBへ接続すると、Bから20を減算し、Aにはブーストが残る経路があった。

### 修正対応

適用量をサウンドバーの UUID ごとに保存する。機器を切り替える際は進行中の処理を待ち、旧機器のブースト解除を試みてから、新機器に対応する記録を読み込む。解除に失敗した旧機器の記録は保持する。解除完了時の記録更新も、処理開始時の UUID に対して行う。

- 変更箇所：[AppModel.swift](../Sources/AmbeoCompanion/App/AppModel.swift) の `reconnectAmbeoClient`、`revertOutstandingBoost`
- 保存処理：[AtmosBoostLedger.swift](../Sources/AmbeoCore/Audio/AtmosBoostLedger.swift)
- 確認：AとBの適用量が独立し、Aの解除がBの記録を変更しないことを自動テストで確認。2台の実機間の切り替えは未確認。

## 検証結果

- アプリのビルド成功。
- `AMBEO_INTEGRATION=1 swift test`：7件すべて成功。
- 実機の音量変更・読み取り・ブースト解除・復元が成功。終了後に音量25への復元を再確認した。
- テスト実装：[RecoveryTests.swift](../Tests/AmbeoCoreTests/RecoveryTests.swift)
- 詳細と制約：[検証記録](VALIDATION.md)
