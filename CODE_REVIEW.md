# Ambeo Companion — レビュー / 修正記録

このファイルはローカルのレビューと修正の記録です。リポジトリには含めません（`.gitignore`）。新しいレビューは下に追記し、対応したら同じ節に結果を残します。

---

# レビュー 2026-09-22

> スコープ: 全ソースファイル（AmbeoCore / AmbeoCompanion / Experiment / Scripts）

---

## 全体評価

**良い点**: アーキテクチャの分離（AmbeoCore / AmbeoCompanion）、Swift 6 並行処理（actor, `@MainActor`, `Sendable`）の適切な活用、AsyncStream によるイベント駆動設計、ログの階層化（Network / Audio / UI / Lifecycle）など、全体として質の高いコードです。

以下、優先度順に問題点を挙げます。

---

## 🔴 高優先度（バグ / 潜在的な不具合）

### 1. `AmbeoClient.set()` — エコー抑制の文字列比較が脆弱

```swift
// set() 内
expectedEchoValues[endpoint.path, default: []].insert("\(v)")

// notifyUpdate() 内
let valStr = "\(newValue)"
let isEcho = expectedEchoValues[path]?.contains(valStr) == true
```

`Any` 型の `"\(value)"` 文字列化で比較しているため、異なる型・値が同じ文字列になるケース（例: `Int(1)` と `String("1")`）でエコー抑制が誤動作します。AMBEO API の値は `Int` / `Bool` / `String` が混在するため、**型付きのキー**（例: `"\(type(of: v)):\(v)"`）を使うべきです。

### 2. `AmbeoClient` — `stateCache` / `latestValues` が `Any` 型

```swift
private var stateCache: [String: Any] = [:]
private var latestValues: [String: Any] = [:]
```

型安全性が失われています。`register` 内で `E.Payload` として格納し、`getValue` で `as? E.Payload` にキャストしているため、型不一致時は `nil` が返り**サイレントに失敗**します。`any Decodable` ではなく、`Any` を避けるための型消去ラッパー（例: type-erased box）を検討してください。

### 3. `AppModel.reconnectAmbeoClient()` — 旧クライアントの停止が非同期

```swift
if let oldClient = ambeoClient {
    Task { await oldClient.stopObserving() }  // ← 非同期
}
ambeoClient = nil  // ← 即座に nil
```

`stopObserving()` が完了する前に新しいクライアントが作成され、**両方のポーリングが短時間並行**する可能性があります。`await` で停止を待ってから新クライアントを作成する、または `ambeoClient` の代入を停止完了後に遅延させるべきです。

### 4. `AppModel` — `networkDevices` の `onChange` が頻繁に設定ウィンドウを開く

```swift
.onChange(of: appModel.networkDevices) { _, _ in
    if appModel.settings.ambeoUid.isEmpty {
        openSettingsWindow()
    }
}
```

mDNS によるデバイスリストはネットワーク状況で頻繁に変動します。`ambeoUid` が空の状態でデバイスの増減があるたびに設定ウィンドウがポップアップし、**ユーザーを困惑**させます。初回起動時のみ（例: `@State private var hasShownFirstRun = false`）に限定すべきです。

### 5. `AmbeoClient.processPollResponse` — ハンドラーの例外が握りつぶされる

```swift
try? await handler(itemValueData)
```

`try?` で例外が完全に無視されます。デコード失敗やネットワークエラーがログに残らず、**デバッグが困難**になります。最低限 `Logger.network.warning` で記録してください。

---

## 🟡 中優先度（設計 / 保守性）

### 6. `AppModel` が 723 行 — 責務が多すぎる

設定永続化、mDNS 検出、オーディオデバイス監視、メディアキー、Atmos Boost、通知、ショートカット…を 1 クラスに集約しています。以下のように分割すると保守性が向上します：

| 分割先 | 責務 |
|---|---|
| `SettingsStore` | `AppSettings` の永続化・ debounce |
| `DeviceDiscovery` | mDNS browse + 再接続判定 |
| `AudioFormatMonitor` | CoreAudio フォーマット監視 + fallback |
| `MediaKeyInterceptor` | CGEventTap + hog 判定 |
| `AtmosBoostController` | Atmos 検出 → boost 適用/解除 |

### 7. `VolumeOverlayManager.show()` — 11 個の optional パラメータ

```swift
func show(
    volume: Double? = nil,
    isMuted: Bool? = nil,
    isAmbeoMode: Bool? = nil,
    ambeoLevel: String? = nil,
    isNightMode: Bool? = nil,
    isVoiceEnhancement: Bool? = nil,
    isEcoMode: Bool? = nil,
    maxIdleTime: Int? = nil,
    powerTarget: String? = nil,
    audioPreset: String? = nil,
    isAtmos: Bool? = nil
)
```

「望遠鏡 API」で可読性が悪いです。`VolumeOverlayState` 自体を引数に受け取り、`nil` 以外のフィールドのみ上書きする形にすると簡潔になります：

```swift
func show(_ state: VolumeOverlayState)
```

### 8. `AudioPhysicalFormat.isAtmosOrMultichannel` — マジックナンバー

```swift
|| formatID == 1_836_344_180  // 'mat$'
|| formatID == 1_836_344_107  // 'mat+'
|| formatID == 1_667_509_043  // 'cea3'
|| formatID == 1_667_588_915  // 'cmlp'
```

FourCC を `UInt32` リテラルで書いているため意図が伝わりにくいです。以下のように定数化してください：

```swift
private enum FourCC {
    static let dolbyMat2 = UInt32(0x6D617424)   // 'mat$'
    static let dolbyMatPlus = UInt32(0x6D61742B) // 'mat+'
    static let dolbyDigitalPlus = UInt32(0x63656133) // 'cea3'
    static let trueHD = UInt32(0x636D6C70)       // 'cmlp'
}
```

### 9. `SimpleFileLogHandler` — 1 ログごとにファイルを開閉

```swift
private func writeWithRotation(_ line: String) {
    Self.fileLock.lock()
    defer { Self.fileLock.unlock() }
    if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
        fileHandle.seekToEndOfFile()
        fileHandle.write(data)
        fileHandle.closeFile()  // ← 毎回 close
        ...
    }
}
```

高頻度ログ時に I/O 負荷が大きいです。`FileHandle` を保持し、ローテーション時のみ close/reopen する方が効率的です。

### 10. `SettingsView` — `availableAudioDevices` が `onAppear` 時のみ更新

```swift
.onAppear {
    availableAudioDevices = AudioDeviceMonitor.shared.allOutputDevices
    ...
}
```

USB デバイスの接続/切断時にリストが更新されません。`AppModel.currentAudioDevice` の変更を監視して再取得する、または `AudioDeviceMonitor` から `AsyncStream` を公開して購読するべきです。

---

## 🟢 低優先度（スタイル / 軽微な改善）

### 11. `AmbeoClient.set()` — 変更操作に HTTP GET を使用

```swift
request.httpMethod = "GET"
```

`setData` は状態を変更する操作なので、REST 的には `POST` が適切です。AMBEO API の制約であればコメントで理由を明記してください。

### 12. `AmbeoClient` — 再接続時のバックオフなし

ポーリング失敗時に固定 3 秒 / 5 秒でリトライしています。デバイスが長時間オフラインの場合、不要なネットワークトラフィックが発生します。指数バックオフ（3s → 6s → 12s → 最大 60s）を検討してください。

### 13. `handleMediaKey` — 音量パーセンテージの計算

```swift
let pct = maxVol > minVol ? Double(newVol - minVol) / Double(maxVol - minVol) : 0.0
```

デバイスの min/max 範囲に対する相対値です。AMBEO が 0-100 なら問題ありませんが、将来 min ≠ 0 のデバイスに対応する場合、OSD 表示と実音量の乖離が生じます。コメントで前提を明記してください。

### 14. `VolumeOverlayState` に `@MainActor` が未付与

`VolumeOverlayManager` が `@MainActor` なので実害はありませんが、`@Observable` クラスとして `@MainActor` を明示すると意図が明確になります。

### 15. `Package.swift` — Experiment ターゲットがリリースビルドに含まれる

```swift
.executableTarget(name: "DiscoverAmbeo", ...)
.executableTarget(name: "FallbackAudioFormat", ...)
.executableTarget(name: "HookVolumeAndMute", ...)
```

`swift build -c release` でこれらもビルドされます。`swiftSettings` で `-D DEBUG` を付与する条件分岐や、別パッケージへの分離を検討してください。

### 16. `LogManager` — DEBUG 時のログパスが `#filePath` 依存

```swift
URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    ...
```

ファイルの移動でログ先が変わります。`CommandLine.arguments` や環境変数で上書きできるようにすると開発が楽になります。

### 17. 小規模なタイポ

| ファイル | 箇所 | 内容 |
|---|---|---|
| `FallbackAudioFormat/main.swift` | 1 行目コメント | `Dolny` → `Dolby` |
| `HookVolumeAndMute/main.swift` | 2 箇所 | `Currnt` → `Current`、`Taget` → `Target` |
| `AppModel.swift` | `handleMediaKey` | `Swift.max` / `Swift.min` の `Swift.` 接頭辞は不要（`Foundation` import 済み） |

---

## 🏗️ アーキテクチャ面での総評

| 項目 | 評価 |
|---|---|
| 層分離 (Core / App) | ✅ 良好。`AmbeoCore` は UI 非依存で再利用可能 |
| 並行処理 | ✅ actor + `@MainActor` + `Sendable` の使い方が適切 |
| イベント駆動 | ✅ `AsyncStream` による一方向データフローが明快 |
| エラー処理 | ⚠️ `try?` の多用で失敗が可視化されない箇所が多い |
| テスタビリティ | ⚠️ `AudioDeviceMonitor.shared` シングルトンがモック困難。プロトコル抽象化を検討 |
| ドキュメント | ✅ README が詳細で、権限設定の注意点まで記載 |

---

## 推奨アクション（優先度順）

1. **エコー抑制の型安全化**（#1）— 実バグの温床
2. **`reconnectAmbeoClient` の停止待機**（#3）— レースコンディション
3. **`onChange` の初回起動限定化**（#4）— UX 問題
4. **`try?` のエラーログ追加**（#5）— 運用時のデバッグ
5. **`AppModel` の分割**（#6）— 中長期の保守性
6. **FourCC 定数化**（#8）— 可読性

全体として、個人開発のメニューバーアプリとして非常に完成度が高く、AMBEO の非公式 API に対する実用的なラッパーとして機能しています。上記の修正を反映すれば、より堅牢で保守しやすいコードベースになると思います。

---

# 対応記録 2026-09-22 — v0.1.4 (build 5)

レビュー指摘をコードと突き合わせ、実バグと小さな改善を `v0.1.4` に入れた。`swift build --target AmbeoCompanion` は成功。メニューバー上の操作確認は未実施。

## 反映

| # | 内容 |
|---|---|
| 1 | エコー抑制キーを `型名:値` にした。`Int(1)` と `"1"` は別値として扱う |
| 3 | `reconnectAmbeoClient` は旧クライアントの `stopObserving()` 完了後に新しい監視を開始する。世代番号で、連続した再接続が古いクライアントを復活させない |
| 4 | デバイス未選択時、最初にデバイスが見つかった一度だけ設定ウィンドウを開く |
| 5 | ポーリングのデコード失敗、再取得失敗、ハンドラー例外を `Logger.network.warning` に出す。`getValue` / `getEntry` の型不一致もログする |
| 7 | `VolumeOverlayManager.show` は状態を書き換えるクロージャを受け取る。触っていない項目は前回値のまま |
| 8 | Dolby 系フォーマット ID を FourCC 文字列（`"mat$"` など）から作る |
| 9 | ログの `FileHandle` を保持し、ローテーション時だけ閉じる |
| 10 | `AudioDeviceMonitor.outputDevicesStream` でデバイス一覧の変化を受け、設定画面の出力デバイス一覧を更新する |
| 11 | `/api/setData` はクエリで値を渡す AMBEO API のため GET のまま。理由をコメントした |
| 12 | 購読・ポーリング失敗は 3 秒から倍々、最大 60 秒。成功したポーリングで 3 秒に戻す |
| 13 | OSD の音量パーセントはデバイスの min〜max 上の位置であり、AMBEO は 0〜100 である前提をコメントした |
| 14 | `VolumeOverlayState` に `@MainActor` を付けた |
| 16 | ログパスは環境変数 `AMBEO_LOG_FILE` で上書きできる |
| 17 | `Dolby` / `Current` / `Target` のタイポ、および不要な `Swift.max` / `Swift.min` を修正 |

### FourCC（#8）の数値

以前の十進リテラルはコメントの FourCC と一致していなかった。

| 旧リテラル | 実際のコード | コメントが意図したコード |
|---|---|---|
| `1_836_344_180` | `mtct` | `mat$` |
| `1_836_344_107` | `mtc+` | `mat+` |
| `1_667_509_043` | `cd+3` | `cea3` |
| `1_667_588_915` | `cec3` | `cmlp` |

`channels > 2` の判定はそのまま。フォーマット ID の一致は、今回からコメントどおりのコードを見る。Apple の `kAudioFormatEnhancedAC3` は `'ec-3'` であり、ここは既存コメントの `'cea3'` を採用している。

## 見送り

| # | 理由 |
|---|---|
| 2 | パスごとに payload 型が異なる。型消去ボックスにしても取り出し時のキャストは残る。型不一致のログ（#5 と合わせて）で足りる |
| 6 | `AppModel` の分割は妥当だが、動作を変えずに 5 クラスへ分ける変更なので、このバグ修正とは分ける |
| 15 | `swiftSettings` の `-D DEBUG` ではリリースビルドからターゲットを外せない。Experiment は `AmbeoCompanion` にリンクされない別実行ファイル。リリースだけなら `swift build -c release --target AmbeoCompanion` |

## 残件（解消済み）

- **スリープ／復帰の actor 監視ライフサイクル**:
  `willSleepNotification` で `ambeoClient` を停止（`await client?.stopObserving()`）および解放し、`didWakeNotification` で再接続するように改修。スリープ中の不要ポーリングや復帰時の接続不全を解消。

---

---

# 対応記録 2026-09-22 — v0.1.6 (build 7)

## 検証結果

### 1. Apple Music 空間オーディオ再生時の実機ログ解析
実機ログ（`~/Library/Logs/io.github.jhorology.AmbeoCompanion/ambeo-companion.log`）を確認したところ、直近の再生ログはすべて以下の状態となっていた：
```text
handleAtmosTransition(isAtmos:) ➔ Dolby Atmos detected (CoreAudio: false, Soundbar: true)
```
- **結論**: 空間オーディオが検出できていたのは AMBEO サウンドバー側 DSP（ネットワーク API `imx8af:decoderAudioFormat`）のおかげであり、macOS の CoreAudio 監視側（`AudioDeviceMonitor`）は一貫して `CoreAudio: false`（未検出）のままであった。

### 2. Apple 公式 Atmos テストデータの抽出とフォーマット解析
Apple Developer の公式 HLS ストリームから E-AC-3 + JOC (Dolby Atmos) オーディオトラックを抽出し、テストファイルを作成して `afinfo` で解析：
- **テストファイル**: `scratch/apple_atmos_test.mp4`
- **解析結果**:
  - `format list [0]`: `16 ch, 48000 Hz, ec+3` (9.1.6 チャンネルレイアウト)
  - `format list [6]`: `6 ch, 48000 Hz, ec-3` (5.1 チャンネルレイアウト)
- Apple が空間オーディオで使用している FourCC は **`ec+3`**（JOC / Atmos 付き）および **`ec-3`** であることを確認。

### 3. FourCC（#8）の数値の真相と実機ログ観測
- 旧リテラル（`1_836_344_180` 等）が表す ASCII コード（`mtct`, `mtc+`, `cd+3`, `cec3`）は、Apple が CoreAudio / HDMI ビットストリーム受渡時に内部的に使用する識別子であった。
- v0.1.4 でコメント側の `mat$` や `cea3` に書き換えたことで、CoreAudio が実際に返すフォーマットと不一致を起こしていた。
- **実機ログでの実測確認**: ユーザー環境での再生時ログより、Apple Music 再生時に CoreAudio から実際に流れてきた生フォーマットが **`formatID=1667443507 'cc+3'` (2ch 16-bit 192kHz)** であることを直接確認。`cc+3` の追加により、Soundbar DSP（約 3 秒遅延）を待たずに CoreAudio から即座に Atmos 判定が可能となった。

### 4. スリープ / 再接続時の Atmos Boost 二重適用（Boost x 2）の判明
- **問題**: Atmos 再生中にスリープまたはネットワーク再接続が走ると、サウンドバー本体の音量がブーストされたまま（例: 30% → 55%）残る。旧実装では `reconnectAmbeoClient` で `appliedAtmosBoost = 0` にリセットしていたため、再接続後に再度 Atmos を検出した瞬間に `55 + 25 = 80%` と二重ブーストが発動し、曲終了時にも元の音量に戻らなくなる危険性があった。

---

## 修正内容

| 項目 | 内容 |
|---|---|
| FourCC 定義の再拡張 | 実測された **`cc+3`** をはじめ、CoreAudio 内部識別子（`cd+3`, `cec3`, `mtat`, `mtbt`, `mtct`, `mtb+`, `mtc+`）、Apple 公式（`ec+3`, `ec-3`, `ac-3`, `cac3`）、一般的定義（`mat$`, `mat+`, `cmlp`）を網羅する `EncodedAudioFormatID.isEncodedSurround` に再設計 |
| `fourCCString` 追加 | `AudioPhysicalFormat` に FourCC 文字列表現プロパティを追加し、非 LPCM フォーマット時に `displayName` に `['cc+3']` 等を表示 |
| フォーマット変更ログの可視化 | `handleAudioFormatChange` で、生 formatID ・ FourCC 文字列・ Atmos 判定フラグを `Logger.audio.info` で出力 |
| スリープ／復帰のクリーンハンドリング | `willSleepNotification` で `ambeoClient` の解放と `await client?.stopObserving()` を実行し、`didWakeNotification` で再接続するように改修（残件を解消） |
| Atmos Boost 二重適用防止 | スリープ突入時にアクティブなブーストをサウンドバー実音量からリバート。さらに `reconnectAmbeoClient` で `appliedAtmosBoost` を不用意に 0 リセットせず引き継ぐことで、再接続時の Boost x 2 を完全防止 |
| バージョン更新 | `v0.1.6 (build 7)` にインクリメント |

---

# レビュー 2026-09-24

> スコープ: 全ソースファイル（v0.1.7 + format コミット時点）。`swift build`（Swift 6.3）は警告ゼロで成功。
> 前回（9/22）の 17 項目は、対応済み 13 件・正当な理由付きで見送り 4 件（#2 Any キャッシュ / #6 AppModel 分割 / #15 Experiment ターゲット）で、記録どおり処理されていることを確認した。以下は**今回新たに発見した問題**。

## 全体評価

前回の指摘はほぼ解消されており、コード品質はさらに上がっている。世代番号（`clientGeneration`）による再接続の競合防止、`echoToken` による型付きエコー抑制、FourCC 文字列ベースのフォーマット判定などは良い設計。

今回の主な発見は、**「非同期操作の完了前にアプリ側状態を更新している」パターン**（Atmos Boost 関連 3 箇所）と、**CGEventTap の無効化・スレッドライフサイクルの未処理**の 2 点。どちらも「ネットワークが不安定なときだけ顕在化する」タイプの潜在バグ。

---

## 🔴 高優先度（バグ / 潜在的な不具合）

### 1. `appliedAtmosBoost` が `client.set` 成功前に更新される（3 箇所）

```swift
// AppModel.swift:567 (handleAtmosTransition isAtmos: true)
appliedAtmosBoost = actualBoost          // ← 状態を先に更新
try? await client.set(...)               // ← 失敗しても更新は取り消されない

// AppModel.swift:585 (handleAtmosTransition isAtmos: false)
appliedAtmosBoost = 0                    // ← 同上
try? await client.set(...)

// AppModel.swift:611 (handleAtmosBoostAmountChanged)
self.appliedAtmosBoost = max(0, self.appliedAtmosBoost + actualDelta)
try? await client.set(...)
```

`set` が失敗（ネットワークエラー、タスクキャンセル）した場合、アプリの状態とサウンドバーの実音量が乖離する：

- **適用失敗** → 解除時に「ブースト分を引く」処理が実行され、ユーザーが設定した音量より**低い音量**になる
- **リバート失敗** → サウンドバー側はブースト継続だがアプリは `appliedAtmosBoost = 0` と認識 → 次の Atmos 検出で**二重ブースト**。v0.1.6 で「再接続時」の Boost x 2 を潰したが、これは**セッション内**の同種バグ
- さらに `handleAtmosTransition` は `Task.isCancelled` をチェックしておらず、起動トランジション実行中に解除が走ると両タスクが競合し、最終状態がセットの到着順に依存する

対照的にスリープハンドラ（AppModel.swift:668 付近）は成功時のみ `appliedAtmosBoost = 0` にしており正しい。パターンが不統一。

**修正案**: `do { try await client.set(...); appliedAtmosBoost = ... } catch { Logger.audio.warning(...) }` の形にし、失敗時は状態を保持したまま（次回リトライ可能にする）。各 `await` の後に `Task.isCancelled` チェックも追加。

### 2. `handleMediaKey` — `set` 失敗時も OSD が「適用済み」を表示

```swift
// AppModel.swift:418, 434
try? await client.set(AmbeoEndpoint.Player.Mute(), valueJSON: ...)
await syncAndShowOverlay(explicitMute: newMute)   // ← 失敗しても表示される
```

サウンドバーが到達不能なとき、OSD は実際には変更されていない音量・ミュート状態を表示する（例: 表示 40% / 実際 30%）。ユーザーに嘘をついてしまう。

**修正案**: `set` を `try` で受け、成功時のみ `syncAndShowOverlay` を呼ぶ（失敗時はログのみ、または OSD にエラー表現を出す）。

### 3. `SystemEventMonitor` — イベントタップのシステムによる無効化を未処理

```swift
// SystemEventMonitor.swift:123
let eventTap = CGEvent.tapCreate(
  tap: .cgSessionEventTap,
  ...
  options: .defaultTap,   // ← アクティブタップ。システムが無効化し得る
  ...
)
```

`CGEventTapCallback` は `systemDefined` 以外のイベント型を解析しておらず、以下の 2 型を無視している：

- `.tapDisabledByTimeout` — コールバックが慢性的に遅いとシステムがタップを無効化
- `.tapDisabledByUserInput` — ユーザーが入力監視の権限を剥奪

無効化後は**ログも警告も出さずメディアキー操作が永久に効かなくなる**。`shouldIntercept` 内で CoreAudio クエリ（`audioDevice(withUid:)` / `currentDefaultDevice` / `checkHogged`）を毎イベント実行しており、デバイスが多数ある環境ではタイムアウト無効化のリスクが現実的。

**修正案**: コールバック先頭で `type == .tapDisabledByTimeout` の場合は `Logger` で警告 + `CGEvent.tapEnable(tap:enable:true)` で再有効化、`.tapDisabledByUserInput` の場合は権限再設定を促すログを出す。

### 4. `SystemEventMonitor` — `context.runLoop` のデータレースとスレッドリーク

```swift
// SystemEventMonitor.swift:86
var runLoop: CFRunLoop?          // ← @unchecked Sendable の Context 内に素の var

// :147 監視スレッド側で書込
context.runLoop = currentRL

// :157 onTermination（別スレッドで実行され得る）で読取
if let rl = context.runLoop { CFRunLoopStop(rl) }
```

- 書込（監視スレッド）と読取（termination ハンドラ）がロックなしで交わるデータレース。`@unchecked Sendable` のためコンパイラは検出しない
- ストリームがスレッド起動前に終了した場合（タスク即キャンセル）、`runLoop` は `nil` のまま `CFRunLoopStop(nil)` となり**何も起きず、スレッドが `CFRunLoopRun()` で永久ブロック** → スレッド + イベントタップのリーク

**修正案**: `NSLock`（または `OSAllocatedUnfairLock`）で保護する。あるいはスレッド側が共有フラグを見て自らのランループを `CFRunLoopStop(CFRunLoopGetCurrent())` で止める形にする。

### 5. `AudioDeviceMonitor.fallback` — `mFormatID` を設定していない

```swift
// AudioDeviceMonitor.swift:424-450
var asbd = AudioStreamBasicDescription()
AudioObjectGetPropertyData(streamId, &address, 0, nil, &size, &asbd)  // 現行 ASBD をコピー
asbd.mSampleRate = format.sampleRate
asbd.mChannelsPerFrame = format.channels
asbd.mBitsPerChannel = format.bitDepth
// ← format.formatID は未使用。現行の mFormatID のまま
```

選択したフォールバックフォーマットの `formatID`（例: `'paus'` int PCM）が現行と異なる LPCM 変種（例: `'f32 '` float PCM）の場合、レート・チャネル・ビット深さだけが変わり**フォーマット ID は現行のまま**になる。`supportedFormats` は LPCM のみフィルタしているが、LPCM 内部の変種差までは扱っていない。

**修正案**: `asbd.mFormatID = format.formatID` を追加（`mBytesPerSample` は既に target の bitDepth から計算済みなので整合する）。

---

## 🟡 中優先度（設計 / 堅牢性）

### 6. `setMaxIdleTime` — 二重同期

```swift
// AppModel.swift:862-865
func setMaxIdleTime(_ seconds: Int) async {
  settings.autoStandbySeconds = seconds   // ← didSet が Task { syncAutoStandbyToSoundbar() } を起動
  await syncAutoStandbyToSoundbar()       // ← さらに明示的にもう一度
}
```

`didSet` 経由の Task と明示呼び出しが**並行して 2 回**ネットワーク呼び出し + OSD 表示を行う。

**修正案**: `didSet` のみで同期させ、明示呼び出しを削除（または逆パターンで統一）。

### 7. `expectedEchoValues` が一致エコー以外でクリアされない

```swift
// AmbeoClient.swift:24, 415
expectedEchoValues[endpoint.path, default: []].insert(echoToken(v))
```

エコーのポーリングが届かないケース（キュー再サブスクライブ、デコード失敗、デバイス再起動）ではトークンが**永久に残り続け**、その後ユーザーがリモコンで同じ値に変更しても「エコー」と誤判定されて OSD が抑制される。

**修正案**: `setupAmbeoSubscription()` 成功時に `expectedEchoValues` をクリアする、またはタイムスタンプ付きで TTL 管理する。

### 8. `SimpleFileLogHandler` — リリースビルドのログファイルに ANSI エスケープが混入

```swift
// SimpleFileLogHandler.swift:86
let color = getColor(level)
let reset = "\u{001B}[0m"
let logLine = "\(timestamp) ... \(color)[\(level.rawValue.uppercased())]\(reset] ..."
```

`logLine` は常に色コードを含み、ファイル書き込みにもそのまま使われる。リリースでは `isConsoleEnabled = false` なので**ファイルだけがエスケープシーケンスで汚染**される。

**修正案**: `config.isConsoleEnabled` のときのみ色を付与する（コンソール用 / ファイル用の 2 種を生成）。

### 9. `AppModel` が依然 880 行（前回 #6 の継続）

前回見送りのまま。Atmos Boost 状態機械（検出 → グレース期間 → トランジション → boost 管理）は既に独立した「状態機械」の形になっており、`AtmosBoostController` への抽出が最も効果的。#1 の修正とセットで状態更新の順序を一元管理できる。

### 10. 無関係なデフォルトデバイス変更でフォーマット監視を再サブスクライブ

```swift
// AppModel.swift:261
self.updateFormatMonitoringForActiveDevice()   // デフォルトデバイス変更のたびに呼ばれる
```

ターゲットデバイスが設定されている場合、対象は常にターゲット側なのに、デフォルトデバイスが変わるたびに（USB DAC 接続など）フォーマットストリームを破棄・再作成している。無害だが無駄。

**修正案**: 再サブスクライブ前に「監視対象デバイス ID が前回と異なるか」を比較し、同一ならスキップ。

### 11. 終了直前の変更が失われる

`debouncedSaveSettings` は 500ms デバウンス。変更から 500ms 以内にアプリを終了すると設定が保存されない。`NSApplication.willTerminateNotification` で `saveSettings()` を呼ぶと解消。

---

## 🟢 低優先度（軽微）

### 12. `AmbeoValueContainer` — 死コード

`DynamicKey.init?(stringValue:)` は必ず成功するため、`guard let key = DynamicKey(stringValue: typeKey) else { throw ... }` は到達不能。`type` キーが空文字列の場合の検証に置き換えるか削除。

### 13. `stopObserving` でポーリングキューを削除していない

`modifyQueue` で作成したキューは停止時に unsubscribe されない。デバイス側が自己回収する可能性はあるが、明示的に空 subscribe で解放すると綺麗。

### 14. `property<T>` の TOCTOU

`AudioObjectGetPropertyDataSize` → `AudioObjectGetPropertyData` の間にプロパティが変わるとバッファサイズが古い値のまま。対象プロパティ（デバイス一覧・ストリーム一覧）ではリスクは低いが、コメントで前提を明記しておくと良い。

### 15. Atmos 解除のグレース期間 500ms が固定

トラック間のデコーダハンドシェイクが 500ms を超えると「解除 → 再検出」でブーストのリバート/再適用が繰り返し音量が振れる。設定項目化、または 1〜2 秒への延長を検討。

### 16. Experiment ターゲットがリリースビルドに含まれる（前回 #15 の継続）

### 17. `stateCache` / `latestValues` が `Any` 型（前回 #2 の継続）

---

## 推奨アクション（優先度順）

| # | 内容 | 工数 |
|---|---|---|
| 1 | `appliedAtmosBoost` を `set` 成功後に更新（3 箇所 + キャンセルチェック） | 小 |
| 2 | `handleMediaKey` の失敗時 OSD 抑制 | 小 |
| 3 | イベントタップ無効化の検出・復旧 | 小 |
| 4 | `runLoop` のロック保護 / スレッド自己停止 | 小 |
| 5 | `fallback` で `mFormatID` を設定 | 極小 |
| 6 | `setMaxIdleTime` の二重同期解消 | 極小 |
| 8 | ログファイルの ANSI 除去 | 極小 |
| 7 | エコー抑制トークンのクリア时机 | 小 |
| 9 | `AtmosBoostController` への抽出（#1 とセット） | 中 |

#1 と #2 は「ネットワークが不安定な環境でしか出ないが、出たらユーザー音量が壊れる」実バグなので、次リリースで対応することを推奨する。#3〜#5 は静かに機能停止する経路なので、こちらも早めに潰しておくと安心。

---

# 対応記録 2026-09-24 — v0.1.8 (build 9)

9/24 レビューをコードと突き合わせて修正した。`swift build` は警告ゼロで成功し、`Scripts/format.sh` も適用済み。実機（メニューバー・サウンドバー）での動作確認はまだしていない。バージョンは `v0.1.8 (build 9)` に上げた。

## 反映

| # | 内容 |
|---|---|
| 1 | Atmos Boost の適用・解除・量の変更は、`client.set` が成功したときだけ `appliedAtmosBoost` を更新する。失敗したら警告ログを出し、状態は変えない。3 つの処理は `enqueueAtmosWork` で 1 本の直列キューに入れ、適用と解除が同時に走らないようにした。送信中のリクエストはキャンセルしない（本体に届いたのにアプリが知らない、という状態を避けるため）。代わりに、実行時に `isAtmosActive` を見直して、古くなった処理は何もせず終わる。ブースト量の変更は実行時の設定値から差分を計算するので、スライダー操作が重なっても最終値に落ち着く。スリープ前の解除は、実行中の Boost 処理が終わるのを待ってから行う |
| 2 | メディアキーの音量・ミュート変更は、`set` が失敗したら OSD を出さない。同じパターンだったショートカット 5 つ（AMBEO Mode / Level / Preset / Night / Voice）にも同じ修正を入れた |
| 3 | イベントタップのコールバックで `.tapDisabledByTimeout` / `.tapDisabledByUserInput` を受けたら、警告ログを出して `tapEnable` で有効に戻す |
| 4 | `Context` の `runLoop` と停止フラグを `NSLock` で保護した。監視スレッドは `CFRunLoopRunInMode`（1 秒）をループで回し、停止フラグを確認する。これで、スレッドがランループを登録する前にストリームが終わっても止まる。タップの無効化・`CFMachPortInvalidate`・`Context` の解放はスレッド側が終了時に行う。以前は termination ハンドラーが `Context` を解放していて、その後にコールバックが走ると解放済みメモリを触る可能性があった。これも同時に直した |
| 5 | 指摘の `'paus'`/`'f32 '` は ASBD のフォーマット ID ではない（LPCM の違いは `mFormatFlags` で表す）。ただし、Atmos 再生直後は現在の ASBD がエンコード形式（`cc+3` など）のことがある。その上にレート・チャンネル数・ビット深度だけを上書きすると、フォーマット ID もフラグも古いままになる。そこで、`kAudioStreamPropertyAvailablePhysicalFormats` から一致する ASBD をそのまま使うようにした。見つからない場合は従来の方法に `mFormatID` の設定を加えたものに戻る。あわせて、`fallback` だけストリーム取得が global スコープで、入力ストリームを掴む可能性があったので output スコープに揃えた |
| 6 | 呼び出し元のない `setMaxIdleTime` を削除した。`didSet` は、サウンドバーが既にその値を持っているとき（`settings.autoStandbySeconds == maxIdleTime`）は同期しない。これで、外部の変更を設定に反映したときに同じ値を書き返して OSD が出るのを防ぐ |
| 7 | `setupAmbeoSubscription` が成功したら `expectedEchoValues` を空にする |
| 8 | ANSI カラーはコンソール出力にだけ付け、ログファイルには色なしの行を書く |
| 11 | `NSApplication.willTerminateNotification` で、保留中のデバウンス保存をキャンセルしてすぐ保存する |
| 12 | `AmbeoValueContainer` の到達不能な `guard` を、`type` が空文字列かどうかのチェックに置き換えた |
| 14 | コメントを足すだけでなく修正した。`property<T>` は 2 回目の呼び出しで返ってきた `size` から要素数を決める（プロパティが縮んだときに未初期化の要素を返していた） |

## 見送り

| # | 理由 |
|---|---|
| 9 | `AtmosBoostController` への抽出は動作を変えないリファクタリングなので、このバグ修正とは分ける（前回 #6 と同じ扱い） |
| 10 | デバイスを抜き差しすると `AudioDeviceID` が同じでもストリームオブジェクトが変わることがあり、「ID が同じならスキップ」は監視漏れにつながる。今の再購読は無駄だが無害なので、このままにする |
| 13 | AMBEO の `modifyQueue` でキューを解放する方法（空 subscribe / unsubscribe の意味）を確認できていない。未検証の API 呼び出しは入れない |
| 15 | グレース期間を延ばすかどうかは、トラック間で実際にどれだけ途切れるかを実機ログで確かめてから決める |
| 16, 17 | 前回の見送り理由と同じ |
