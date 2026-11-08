# コードレビュー（2026-11-08）

過去のレビュー（[CODE_REVIEW.md](CODE_REVIEW.md) / [CODE_REVIEW_2026-10-01.md](CODE_REVIEW_2026-10-01.md)）に引きずられず、その時点の全ソースを独立して読み直した結果。対応は行っていない（指摘のみ）。

## 対象と確認方法

- 対象: `Sources/AmbeoCore`、`Sources/AmbeoCompanion`、`Sources/Experiment`、`Tests`、`Package.swift`、`Scripts`、`Info.plist`、entitlements
- 環境: Apple Swift 6.4.2 / swift-tools-version 6.3 / arm64-apple-macosx27.2

レビューとは別に以下の実行確認を行った。

| 項目 | 結果 |
| --- | --- |
| `swift build -c debug` | 警告ゼロで成功 |
| `swift test` | XCTest 15件（うち2件スキップ）＋ swift-testing 24件、すべて成功 |
| CoreAudio 出力ストリーム実測（本機・6デバイス） | **全デバイスで out streams = 1**（🔴4 の評価に使用。表は同項参照） |
| `swift-format lint -r -p`（`Tests` を含めて実行） | `Tests/` の複数ファイルで `[RemoveLine]` 警告。**ただし `swift-format format -i` は差分ゼロ**（後述 🟢 で原因を解析） |

実機での再現確認は行っていない。実機起因が疑われる項目（🔴3、🟡6 など）は、対応前に実機での現象確認が必要。

---

## 🔴 高優先度

### 1. `Info.plist` に局所ネットワーク系の usage description が無い

**優先度：高／対応済み（2026-11-08）**

#### 指摘

[Info.plist](../Sources/AmbeoCompanion/Info.plist) は `NSAppleEventsUsageDescription` のみ。[SennheiserDiscovery.swift](../Sources/AmbeoCore/Network/SennheiserDiscovery.swift) 27行目の `NWBrowser` は macOS 15 以降で **Local Network 権限**を要求する。`NSLocalNetworkUsageDescription` が無いと、アプリは「ローカルネットワーク」一覧に現れるだけで、**許可プロンプトが出ずアクセスが拒否され得る**。現在検出できているのは手動でトグルした結果の可能性が高い。

#### 推奨対応

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Ambeo Companion finds your AMBEO Soundbar on your local network (mDNS) and reads its state over HTTP.</string>
<key>NSBonjourServices</key>
<array><string>_sennheiser._tcp.</string></array>
```

`LSMinimumSystemVersion` も未指定（`CFBundleShortVersionString` 0.1.26 / `CFBundleVersion` 26）。

#### 対応内容

[Info.plist](../Sources/AmbeoCompanion/Info.plist) に3キーを追加した。

- `NSLocalNetworkUsageDescription` — 局所ネットワーク許可プロンプト用の文言
- `NSBonjourServices` — `_sennheiser._tcp.`（[SennheiserDiscovery.swift](../Sources/AmbeoCore/Network/SennheiserDiscovery.swift) 28行目の browse type と完全一致。コメントで参照を残した）
- `LSMinimumSystemVersion` — `14.0`（`Package.swift` の `platforms: [.macOS(.v14)]` と揃えた）

[install.sh](../Scripts/install.sh) の権限リセットに Local Network を追加した（ad-hoc 再署名で cdhash が変わるため Accessibility / AppleEvents と同じ扱い）。局所ネットワーク権限には公開 API が無いため、アプリ側の Permissions 窓では状態を表示しない。

```sh
tccutil reset LocalNetwork "$BUNDLE_ID" || echo "Warning: Failed to reset Local Network permissions."
```

[PermissionOnboardingView.swift](../Sources/AmbeoCompanion/UI/PermissionOnboardingView.swift) に Local Network 行を追加した（初回オンボーディングとメニューバーの Permissions 窓の両方に出る）。公開 API が無いので**推定表示**に留め、断定しない設計にした。

| 状態 | 表示 | 判定 |
| --- | --- | --- |
| `allowed` | Allowed（緑） | mDNS の結果が1件以上、または接続済みクライアントあり＝閲覧が実際に成功した |
| `probing` | Checking…（緑） | 検索開始から15秒未満（起動・スリープ復帰・ネットワーク切替の猶予） |
| `nothingFound` | No soundbar found（橙） | 15秒以上経過しても結果ゼロ。**拒否と断定せず**「見つからない」とだけ表示 |

- 判定は `LocalNetworkPermissionStatus.init(deviceCount:hasClient:startedAt:grace:)` の純関数。AppModel 側は `discoveryStartedAt`（検索開始時刻）を追加しただけで、既存の `MediaKeyPermission` 列挙型（TCC をポーリングする方）には手を入れていない
- 「Open Settings」は `Privacy_LocalNetwork` ペインを開く。既存のペイン開封処理と重複していたため `MediaKeyPermission.openSystemSettings` → `openPrivacyPane` にリネームして共有した
- **`needsPermissionOnboarding` の判定対象には含めない**（未許可でもアプリは動くため、続行ボタンを止めない）
- 純関数のテストは現状 AmbeoCore 側に test target があるだけでアプリ本体には無い。🟡12 の分割時に移設して守るのが妥当

#### 検証

| 項目 | 結果 |
| --- | --- |
| `plutil -lint Sources/AmbeoCompanion/Info.plist` | OK |
| `swift Scripts/PackageApp.swift` 後の `AmbeoCompanion.app/Contents/Info.plist` | 3キーとも同梱を確認 |
| `codesign --verify --verbose=2 AmbeoCompanion.app` | valid on disk / satisfies its Designated Requirement（entitlements は apple-events のまま不変） |
| `bash -n Scripts/install.sh` | 構文 OK |
| `swift build`（UI 追加後） | 警告ゼロで成功 |
| `swift-format lint`（変更した3ファイル） | クリーン |

**未検証：実機でのプロンプト表示と検出**。Local Network 権限をまだ許可していない状態での初回起動確認が必要。現在のインストール済みアプリは既に手動許可されている可能性が高く、`install.sh` の `tccutil reset LocalNetwork` を通すと再度許可が必要になる。

---

### 2. Stealth Rewind の安全タイムアウトが「ミュート RPC 完了後」に始まる

**優先度：高／対応済み（2026-11-08）**

#### 指摘

[StealthRewindCoordinator.swift](../Sources/AmbeoCore/Audio/StealthRewindCoordinator.swift) の `handleCoreAudioFormatChange` は、`setMute(true)` を発行し `try await muteTask.value`（`URLSession.timeoutIntervalForRequest = 10.0`）を**完了まで待ってから** `startTimeoutTask(for:)` を呼んでいた。

実機が応答しない／切断直後だと **10秒（HTTP）＋5秒（muteTimeout）＝最大15秒間ミュートされたまま**。README が謳う「5-second safety timeout so the soundbar is never left muted」が成立しない。

#### 推奨対応

セッション開始時点（`sessionStartInstant` を設定する箇所）で deadline タイマーを武装し、mute RPC と raced にする。

```swift
startTimeoutTask(for: currentID)   // ミュート発行より前
let muteTask = Task { @MainActor in try await setMute(true) }
```

#### 対応内容

セッション開始直後（`isSuppressingMuteOSD = true` の直後、ミュート状態の読み取りより前）に `startTimeoutTask(for: currentID)` を移した。Step 2 完了後の武装は削除。

- **順序の安全性は維持**：`unmuteIfNeeded` は従来どおり `inFlightMute.value` を待ってから解除するため、遅延したミュートが解除後に着弾して音が消えることはない
- 効果：締切（セッション開始から `muteTimeout`）で `.finishing` に移り、ミュート RPC が戻った瞬間に解除が発火する。従来は RPC 完了後にタイマーが始まるため **RPC + muteTimeout** を待っていた
- ミュート状態の読み取り（これ自体 HTTP）がハングした場合も締切が効く。読み取りが遅れて締切後に戻ると、既存の `phase != .finishing` ガードでミュートは発行されない
- タイマー発火ログを「mute request または format lock の締切超過」と分かる文言に更新。クラス文書に「安全窓はセッション開始から、リクエスト発行前」を明記
- 観測性のため `Phase` / `phase` を `private` → `internal`（`private(set)`）へ。`@testable import` のテストが締切駆動を確認するため

#### 残る上限（🟡14 として追加記録）

ミュート窓の実効上限は `URLSession.timeoutIntervalForRequest = 10秒`（＋解除 RPC）のまま。README の「5秒」を厳密に守るには、ミュート／ミュート解除の各リクエストに短い個別タイムアウト（例 2秒）を付ける必要がある。

#### 検証

新規テスト `slowMuteRequestEndsSessionAtDeadline`（"A mute request slower than the safety window ends the session at the deadline"）：

- `muteTimeout = 60ms`、ミュート RPC を 300ms のブロッキングで模擬
- 120ms 時点で `phase == .finishing`（締切が掃除を握った）かつ解除未発行。RPC 完了後に `mute(true) -> mute(false)` へ到達
- **修正前コードでは同じテストが 5 件の期待値違反で失敗**（`swift test --filter slowMuteRequestEndsSessionAtDeadline` で再現確認済み）。修正後は swift-testing 13件・XCTest 15件すべてパス

---

### 3. Atmos Boost がユーザーのミュートを解除する

**優先度：高／対応済み（2026-11-08・実機での現象確認は未実施）**

#### 指摘

[AppModel.swift](../Sources/AmbeoCompanion/App/AppModel.swift) の `handleAtmosTransition(isAtmos: true)` が `player:volume` を書き込む。同ファイルのコメントどおり **AMBEO は volume 書き込みで自動的にミュート解除**されるため、

> ミュート中に Atmos トラックへ切り替わる → 音が鳴り始める

という UX バグになる。

#### 推奨対応

`handleAtmosTransition` でミュート状態を見て適用をスキップし、ミュート解除時に再適用する。

#### 対応内容

音量書き込みはすべて `setBoostVolume`（apply / revert / adjust の共通関門）を通るので、そこにミュート判定を入れた。

- **`setBoostVolume`**: 書き込み前に `isSoundbarMuted(client)` を確認。ミュート中なら `deferredBoostReasonWhileMuted = action` を記録して `false` を返す。呼び出し側は `appliedAtmosBoost` を更新しないので**台帳にズレが残らない**
- **`isSoundbarMuted(_:)`**: `getValue(Player.Mute())` の生読み取り → 無ければキャッシュ `soundbarState?.isMuted` → どちらも取れない場合は**ミュート扱い**。後で適用できる延後は回収可能、勝手に解除するのは回収不能、という非対称を反映
- **再適用 `replayDeferredAtmosVolumeWork(afterUnmute:)`**: 発火は (a) `handleAmbeoStatusChange` でミュート telemetry が true → false に変わった時、(b) メディアキーで解除した時（telemetry 待ちにしない）。適用先は実行時に再計算し、Atmos 中なら `handleAtmosBoostAmountChanged`（delta = 設定値 − 適用済み。apply とスライダー変更を両方カバー）、ステレオなら `handleAtmosTransition(isAtmos: false)`（revert）。**ミュート中に Atmos を跨いだ場合も向きが正しくなる**
- `isShuttingDown` と `settings.atmosBoostAmount > 0` でガード
- README（EN / JA）に「ミュート中は適用せず、解除した瞬間に適用」を明記

#### 残る課題

- **終了時の音量戻しはミュートを解除する**：`prepareForTermination` → `revertOutstandingBoost` → [AmbeoClient.swift](../Sources/AmbeoCore/Network/AmbeoClient.swift) 411〜420行目の `removeVolumeBoost` は volume を書く。Quit 前にミュートしていたら解除される（台帳を戻す方が重要なので現状は許容。🟢に追記）
- ミュート判定のコストは**実質ゼロ**（指摘を受けて確認）。`AmbeoClient.getValue`（336〜347行）は `latestValues` のメモリ読み取りで、未キャッシュ時のみ network へ出る。`latestValues` は long-poll 購読（`/api/event/pollQueue`、`timeout=2000`）が push で更新し、`player:mute` は登録済み。コード側のコメントにも明記した
  - 残る前提：購読キューが死んでいると `latestValues` が古くなるため、ミュート判定も古くなる。これは音量・Atmos など他機能と同じ前提で、個別に対策しない（🟡7, 8 のキュー整理で購読の健全性を上げれば自動的に改善する）
- AppModel に test target が無いので**単体テスト無し**（🟡12 の分割で `setBoostVolume` の判定ごと移設して守る）

#### 検証

| 項目 | 結果 |
| --- | --- |
| `swift build` / `swift build -c release` | 警告ゼロで成功 |
| `swift-format lint`（AppModel.swift） | クリーン |
| `swift test` | 全パス（AmbeoCore のみ。本変更はアプリ側） |
| 実機でのミュート中 Atmos 切替 | **未実施**。要確認手順：ミュート → Atmos トラックへ切替 → 音が出ないこと → 解除時に +N% されることをログ（`Atmos Boost apply skipped: soundbar is muted` / `replaying deferred Atmos Boost`）で確認 |

---

### 4. CoreAudio の出力ストリームを常に「1本目」だけ見ている（WON'T FIX）

**優先度：低／WON'T FIX（2026-11-08）**

#### 指摘

[AudioDeviceMonitor.swift](../Sources/AmbeoCore/Audio/AudioDeviceMonitor.swift) 322 / 359 / 399 / 464行目が `streamIds.first` 固定。

```swift
let streamIds = property(..., selector: kAudioDevicePropertyStreams,
                         scope: kAudioDevicePropertyScopeOutput, ...)
guard let streamId = streamIds.first else { return [] }
```

出力ストリームを複数持つデバイスでは、**再生に使われているストリームと別のストリーム**のフォーマットを読む。`isAtmosOrMultichannel` 判定・Fallback 適用・Stealth Rewind のトリガーがズレる可能性。

#### 対応不要とした理由（本機実測）

`kAudioDevicePropertyStreams`（scope=Output）を列挙した実測では、**全デバイスが出力ストリーム1本**だった。

| デバイス | out streams |
| --- | --- |
| DELL S3221QS（DisplayPort） | 1 |
| AW3225QF（DisplayPort） | 1 |
| Mac Studio Speakers | 1 |
| Babyface Pro (72990454)（RME・多ch USB IF） | 1 |
| C270 HD WEBCAM / Red Barchetta Microphone | 0（入力のみ） |

**多チャンネルの RME Babyface Pro ですら出力ストリームは1本**で、チャンネル数はストリーム内の element として表現される。USB / DisplayPort / HDMI / 内蔵スピーカーという本製品の想定経路では `streamIds.first` で正しく、一般化のコストが見合わない。

残る理論上の例外は Dante / AVADANT 系のネットワークオーディオ機器など複数出力ストリームを公開するデバイスで、AMBEO Mini 単体ツールの想定ユーザーからは外れる。Aggregate Device（Audio MIDI Setup で作成）は**本機で未実測**。

#### 診断ログも入れない判断

**Mac で Atmos を AMBEO に届く形で出力するのは HDMI パススルー（ビットストリーム）時のみ**。よって Atmos 判定が意味を持つデバイス＝HDMI / DP オーディオ出力のクラスに限定され、そのクラスは実測で全て出力ストリーム1本（DELL S3221QS・AW3225QF）。逆に複数出力ストリームを公開する Dante / AVADANT 系は AMBEO Mini に Atmos を届けられないので、1本目しか見ないことが**実害に繋がらない**。

したがって一般化も診断ログも入れない。`streamIds.first` はこの製品の設計として正しい選択であり、🔴4 は **WON'T FIX** でクローズ。

---

## 🟡 中優先度

### 5. `Stringified` が数値を黙って nil にする

**優先度：中／対応済み（2026-11-08）**

[AmbeoModels.swift](../Sources/AmbeoCore/Network/AmbeoModels.swift) が `try? container.decode(String.self)` のみ。実機が `"step":"1"`（文字列）を返すことは [VALIDATION.md](VALIDATION.md) で確認済みだが、**固件更新で `"step":1`（数値）になった瞬間**に `min/max/step` が nil となり、`handleMediaKey` と Atmos Boost の `?? 0 / ?? 100 / ?? 1` に暗黙で落ちる。**音量上限100固定・step 1固定**になり、ログにも出ない。

#### 対応内容

- **`Stringified` のデコードを拡張**: 文字列 → Int → Double → Bool の順に試す。整数値の Double は `Int64` に正規化してから `T(...)`（`1.0` → `1`）。非整数 Double を Int フィールドが受けた場合と、object / array / null は従来どおり nil（throw しない）
- **派生して見つけたより現実的なバグを同時に修正**: `Edit` の合成 Decodable が**全キーを必須**にしていた。`{"edit":{"step":2}}` のように firmware が一部だけ返すと `keyNotFound: min` で**エントリー全体が失敗**し、`getEntry` が nil → step だけでなく min/max も含めて既定値へ落ちる。`Player.Volume.Edit` と `Audio.Preset.Edit` を `decodeIfPresent` ベースの tolerant な `init(from:)` に変更

#### 検証

新規 `Tests/AmbeoCoreTests/StringifiedDecodingTests.swift`（8テスト）。

| コード | 結果 |
| --- | --- |
| 修正後 | 8テスト全パス（全体でも swift-testing 21件・XCTest 15件中2スキップで全パス） |
| `git show HEAD:` の旧 `Stringified` に戻して実行 | **5テスト失敗・9 issues**（数値 / 整数 Double / String型フィールドの数値 / JSON bool / 部分 edit オブジェクト） |
| `swift build` / `swift-format lint` | 警告ゼロ・クリーン |

### 6. 電源断をまたいだ Boost 台帳の不整合（WON'T FIX／前提が誤り）

**優先度：—／WON'T FIX（2026-11-08）**

元の指摘は「サウンドバーが電源断→再起動するとハードの音量はリセットされるが台帳は `boost > 0` を保持する」で、`powermanager:target` の standby→online で台帳をリセットする手当てを提案していた。

**実機仕様の訂正**: AMBEO は最後に設定された音量を保持する（スタンバイ／電源断をまたいでリセットされない）。よって

- 再起動後もハード音量は `base + boost` のままなので、台帳の `boost > 0` と**整合している**。元の指摘の「Boost されない」「二段階ぶん下がる」は発生しない
- **提案した台帳リセットは逆効果で危険**: 台帳だけ 0 にすると、次の Atmos で `appliedAtmosBoost == 0` となり、既に boost 済みの音量へさらに boost を加算する。**二段階ぶんの爆音**が起きる。音量書き込みを伴わないリセットは安全に成立しない

コードは既に「台帳のクリアは成功した音量書き込みの直後だけ」という不変条件を満たしている。

| 箇所（AppModel.swift） | クリア／更新の条件 |
| --- | --- |
| 855 / 871 / 898行目 | apply / revert / adjust の `set` 成功時 |
| 911行目 | `removeVolumeBoost` が `true`（＝書き込み成功）を返した時だけ `record(0)` |
| 988行目 | スリープ前の revert が成功した時だけ 0。失敗時は `Preserving boost state across wake.` で保持 |

#### 残る既知の軽微なズレ（🟢 相当・要実機確認）

Boost 適用中にユーザーがリモコン等で音量を変えると、台帳は boost を保持したままなので Atmos 終了時に「ユーザーの新音量 − boost」になる（boost ぶんだけ低い）。**電源断とは無関係**。解消には外部音量変更時の台帳更新方針が必要だが、ユーザー意図と Boost の内訳を区別できないため単純解は無い。実機で体感されるなら対応検討。

#### 設計不変条件として明記（将来のレビュー向け）

`AtmosBoostLedger` をクリアしてよいのは、**対応する音量書き込みが成功した直後だけ**。電源断・再接続・スリープ復帰をトリガーにクリアしてはならない（二重 Boost → 爆音）。

### 7. `URLSession` を一度も invalidate しない

**優先度：中／対応済み（2026-11-08）**

[AmbeoClient.swift](../Sources/AmbeoCore/Network/AmbeoClient.swift) で生成する `URLSession` を、生成したクライアントの寿命が終わっても invalidate していなかった。`stopObserving()` は poll task を止めるだけで、ログ上 1起動で28回の再接続（`Subscribed queue` の出現数）があり、Wake / IP 変更のたびにセッションとコネクションプールが残っていた。

#### 対応内容

- **`AmbeoClient.shutdown()` を追加**（`stopObserving()` ＋ `session.finishTasksAndInvalidate()` ＋ `isShutDown` フラグ）。`stopObserving()` は「クライアントを使い続ける」呼び出し側のために据え置き、寿命が終わる場所だけで `shutdown()` を呼ぶ
- **`shutdown()` を呼ぶ箇所**（＝クライアントを破棄する4経路）:

| 経路 | 位置 | 注意点 |
| --- | --- | --- |
| 再接続で旧クライアント | AppModel.swift 296行目 | 旧セッション上の `revertOutstandingBoost`（HTTP）を**終えた後**に無効化。早期 return しても無効化が飛ぶようにガードを統合した |
| 生成中に世代が古くなった新規クライアント | 323 / 332行目 | `self.ambeoClient === client` のとき先に nil へしてから shutdown（生存中のセッションを殺さない） |
| スリープ時 | 1032行目 | 復帰時は新しいクライアントを作るので旧クライアントは破棄 |
| 終了時 | 961行目 | Boost 戻しの後 |

- **使用済みクライアントの後片付け**: `set` は `URLError(.cancelled)`、`fetchDirectValue` は nil、`startObserving()` は再武装しない（無効化したセッションへリクエストを流さない）
- テスト2件（`AmbeoClientShutdownTests`）: 停止後に書き込みが `.cancelled` で即失敗すること／読み取りが nil であること、`shutdown()` の冪等性

#### 残る確認

実機で長時間（スリープ／Wake を繰り返す）運用し、セッション数が増え続けないことを確認する。ログの `AmbeoClient session invalidated for ...` が再接続回数と一致するはず。

### 8. 機器側イベントキューを毎回新規作成し、捨てている

**優先度：中／部分対応（2026-11-08・アプリ側のみ）**

`setupAmbeoSubscription()` は `queueId=""` で毎回新しい機器側キューを作り、旧キューを解放しない。組み込み機のキュー枠は有限で、Wake を繰り返す運用では実機側に古い購読キューが溜まる可能性がある。

#### 対応内容（アプリ側）

- `SennheiserDiscovery.browse()` は呼び出しごとに `DispatchQueue(label: "io.github.jhorology.SennheiserDiscovery")` を新設していた（本機ログで **1起動あたり NWBrowser 30回**）。**共有の static シリアルキュー**に変更。NWBrowser はキュー共有を公式にサポートしており、結果は小さいので直列化の影響は無い

#### 機器側キューは意図的に触っていない

`/api/event/modifyQueue` の**解放セマンティクスが実機で未検証**のため。空 `subscribe` / `unsubscribe` の意味が分からずに呼ぶと、購読が黙って死ぬリスクがある。前レビュー [CODE_REVIEW.md](CODE_REVIEW.md) 583行目も「未検証の API 呼び出しは入れない」と明記しており、同じ判断を守った。

実機で確定させる実験:

1. サウンドバーの電源を入れ直さずに Wake／再接続を 20 回ほど繰り返す
2. `pollQueue` が古い `queueId` をいつまで受け付けるか、購読 push が止まる瞬間があるかをログで確認
3. 解放 API（`modifyQueue` の `unsubscribe` 配列、専用の delete 系エンドポイント等）を DevTools／実機観測で特定できたら、`shutdown()` 内で旧キューを unsubscribe する（`currentQueueId` を保持しておく）

### 9. `reconcileAudioDeviceSelection` が自分自身のタスクをキャンセルする

**優先度：中／対応済み（2026-11-08・実機確認は未実施）**

`reconcileAudioDeviceSelection()` のループ内で `settings.audioDeviceUid = device.uid` すると、didSet → `startMonitoringAudioDevice()` → **実行中の `monitoringOutputDevicesTask` を cancel** して再生成していた。以降の `updateFormatMonitoringForActiveDevice()` は `Task.isCancelled == true` の状態で走り、UID 復旧のたびにストリームが総入れ替えされ、Stealth Rewind の `resetObservedFormat()` も連続発火していた。

#### 対応内容（当初案ではなく didSet 側を修正）

当初の推奨は「書き込みを次イテレーションへ逃がす」だったが、実装は **根本の didSet 側**を直した。`settings.audioDeviceUid` 変更時に `startMonitoringAudioDevice()` を呼ばず、次で置き換えた:

- `updateFormatMonitoringForActiveDevice()` — UID はその場で解決される（`AudioDeviceMonitor.audioDevice(withUid:)`）。`startMonitoringFormat` は監視 source が不変なら early-return する冪等関数
- 既定出力デバイスが新 UID と一致するときだけ `applyFallbackFormatIfNeeded(for:)` — 旧コードの「再生成直後に `defaultDeviceStream` が現値を yield して発火する」経路を明示的に再現
- `restartSystemEventMonitorIfNeeded()` は**維持**（メディアキー監視は起動時に UID を捕捉するため、UID 変更で再スタートが必要）

再購読しなくなった理由: `outputDevicesStream` / `defaultDeviceStream` は**全デバイス**を観察しており、選択 UID の変化で購読し直す必要がない。

#### 効果

| 旧 | 新 |
| --- | --- |
| キャンセル済みタスク内で `updateFormatMonitoringForActiveDevice()` が走る | 走らない（呼び出しは存活中のタスク／didSet から） |
| UID 復旧ごとに CoreAudio サブスクリプションを総入れ替え。`defaultDeviceStream` は購読時に現値を yield するため、復旧のたびに `Default audio device changed:` が即発火 | 再購読なし。ログも増えない |
| `resetObservedFormat()` が連続発火（取り消し＋再生成で2回） | 1回 |

#### 検証

`swift build -c release` 警告ゼロ、`swift test` 全パス（XCTest 15件・2スキップ／swift-testing 22件）、`swift-format lint` クリーン。

**AppModel にテストターゲットが無く単体テストは追加できない**（🟡12 で分離すべき対象）。実機での確認シグナル: ログに `Recovered display output UID: ...` が出た**直後**に `Default audio device changed:` が続いて出なければ修正が効いている（旧コードでは再生成時の初期 yield で必ず続いた）。

### 10. TCC 権限の2秒ポーリングが常時運転

**優先度：中／未対応**

AppModel.swift 201〜207行目（`monitoringPermissionsTask`）が2秒ごとに `AXIsProcessTrusted()` ＋ `AEDeterminePermissionToAutomateTarget()`（→ `NSRunningApplication` 列挙）を呼び続ける。取り消し検知は [SystemEventMonitor.swift](../Sources/AmbeoCore/Utilities/SystemEventMonitor.swift) の tap-disabled callback とスレッド内チェック（188行目）で既にカバー済み。**Permissions 窓が開いている間だけ**回すだけで十分。

### 11. mDNS 応答の信頼性チェックが無い

**優先度：中／未対応**

`SennheiserDiscovery` は TXT の `uuid/serial/name/ip` をそのまま採用し、AppModel は `uuid == settings.ambeoUid` で IP へ HTTP リクエストを投げる。`openURL("http://\(device.ip)")` も同様（AmbeoCompanionApp.swift 138行目）。LAN 上で `_sennheiser._tcp` を広告すれば**任意の IP へリクエスト／ブラウザを開かせる**ことが可能。UID 形式（`ambeosoundbar…-<UUID>`）と IP の妥当性（link-local / マルチキャスト以外）の検証が安価。

### 12. `AppModel.swift` 1187行・責務過多でテスト不能域がある

**優先度：中／未対応**

`@Observable AppModel` に7責務（設定永続化 / 接続 / 検出 / CoreAudio / メディアキー / Atmos / OSD / 電源通知）。Stealth Rewind と Recovery は手厚くテストされている一方、**再接続・IP 変更・スリープ復帰・Boost 台帳**（過去に実バグが出た場所）はテスト不能。`handleAtmosTransition` の音量クランプ計算、`reconcileAudioDeviceSelection`、`debouncedReconnectIfIPChanged` の判定を純関数化すれば `AmbeoCoreTests` で守れる。

### 13. 終了処理に上限時間がない

**優先度：中／対応済み（2026-11-08）**

[AmbeoCompanionApp.swift](../Sources/AmbeoCompanion/App/AmbeoCompanionApp.swift) が `.terminateLater` を返して `prepareForTermination()` の完了を待つ。中に HTTP が複数直列（unmute → boost revert → client 停止）で、**実機が応答しない状態での Quit は数十秒ハング**した。

#### 対応内容

- `CompanionAppDelegate` に `terminationGrace = .seconds(2.5)` を追加し、`withTaskGroup` で `prepareForTermination()` と **2.5秒の猶予を競わせ、先に終わった方で `cancelAll()` → `reply(toApplicationShouldTerminate: true)`**
- 超過時は `Termination cleanup exceeded the grace period; quitting with unfinished work.` をログ（Quit が遅れた事実が残る）
- **中断が安全な理由**: 台帳（Boost / `needsUnmute`）は書き込み成功時にだけクリアされる（🟡6 の不変条件）。よって cleanup を途中で切っても状態は残り、次回起動時に `isAtmosActive = appliedAtmosBoost > 0` と再接続時の `revertOutstandingBoost` / `needsUnmute` 再試行が回収する

#### 残る挙動

- 猶予 2.5秒は方針（長くすれば cleanup が完了しやすい分、Quit が遅れる）。実機で Quit が体感できるかを 🟡14 の 2秒タイムアウトと合わせて確認
- 途中キャンセルされた HTTP はプロセス終了まで残る（終了処理なので実害なし）

---

### 14. ミュート系リクエストの HTTP タイムアウトが全局 10 秒

**優先度：中／対応済み（2026-11-08・🔴2 の対応中に発見）**

[AmbeoClient.swift](../Sources/AmbeoCore/Network/AmbeoClient.swift) の `URLSessionConfiguration.timeoutIntervalForRequest = 10.0` は全エンドポイント共通。Stealth Rewind のミュート／解除は「戻らないリクエスト」を1回しか追えないため、🔴2 対応後の実効的なミュート窓も **10秒（RPC）＋解除 RPC** が上限だった。

#### 対応内容

- `AmbeoClient.interactiveTimeout = 2.0` を追加。`set` / `getEntry` / `getValue` / `fetchDirectValue` / `removeVolumeBoost` に **任意の per-request timeout**（`nil` は従来どおり全局10秒）を受けさせる
- **適用した呼び出し**（ユーザー体験を壊す書き込みだけ）: Stealth Rewind の `setMute` クロージャ、メディアキーのミュート、`setBoostVolume`（apply / revert / adjust）、スリープ前の Boost 戻し、`revertOutstandingBoost` → `removeVolumeBoost`、`isSoundbarMuted` のコールドキャッシュ読み
- **あえて適用しなかった**: メディアキーの音量書き込み（ユーザー操作で、短すぎると正常な遅い書き込みを落とす）、登録・購読・poll 系トラフィック

#### 効果（ミュート窓の実効上限）

| 段階 | 実効上限 |
| --- | --- |
| 🔴2 前 | タイムアウト武装が遅く、10秒（RPC）＋解除 RPC |
| 🔴2 のみ | 5秒タイマーだが解除 RPC が10秒窓 → 最悪 ~15秒 |
| 🔴2 ＋ 🟡14 | **5秒タイマー ＋ 解除書き込み ≤2秒**（接続確立含む）で ~7秒 |

- 解除が失敗した場合、`needsUnmute` は保持され再接続時に再試行される（StealthRewindCoordinator.swift 49 / 325〜334行目）。**タイムアウトを短くした分、この回収経路への依存が上がる**ことを明記

#### 検証

新規 `Tests/AmbeoCoreTests/AmbeoClientTimeoutTests.swift`：5秒応答しない `URLProtocol` に対し 0.4秒の timeout で `set` を実行 → **0.41秒で `.timedOut`**（全局10秒窓に入らないことを確認）。全体は swift-testing 22件・XCTest 15件（2スキップ）で全パス、`swift build -c release` 警告ゼロ。

---

## 🟢 低優先度・衛生面

- **`Package.resolved` が `.gitignore`（9行目）**。実行物アプリなので再現ビルドのためにコミットする側。
- **CI が無い**（`.github` 等なし）。`swift build -c release` ＋ `swift test` ＋ `swift-format lint` の3行で守れる。
- **`Scripts/format.sh`（27〜30行目）の TARGETS に `Tests` が無い** — ただし lint 警告の主原因はそれではない。`.swift-format` が `lineBreakBeforeEachArgument: true` のため、整形済みコードの引数1行ごとの改行を lint が `[RemoveLine]` で全部指摘する（`Sources/` でも同じ。最小再現：2引数の呼び出しを整形すると lint が5件出す）。したがって **Tests を TARGETS に足しても lint 警告は消えない**
  - CI のチェックは `swift-format format -i` ＋ `git diff --exit-code`（整形の定着確認）にして、lint は外すか、`lineBreakBeforeEachArgument: false` にして整合させる
- `#available(macOS 13.0, *)`（AppModel.swift 215 / 219行目）は `platforms: [.macOS(.v14)]` なので常に真の死んだ分岐。
- `checkHogged`（AudioDeviceMonitor.swift 309〜311行目）`property(...).first ?? -1 != -1` は意味は正しい（`??` の優先度が高い）が意図が読めない。`( … .first ?? -1) != -1` と括弧を。
- AudioDeviceMonitor.swift 141〜145行目のコメントアウト済み `extension Notification.Name` は削除。
- SettingsView.swift 216行目の `"0.1.26"` ハードコード（Info.plist と二重管理）。
- ログノイズ: 停止時に `Polling connection interrupted: cancelled.`（NOTICE、AmbeoClient.swift 241行目）。取り消しは無言化を。DEBUG は `.trace` で全システムイベントを disk へ書き、実測で `Logs/ambeo-companion.log` が1.5MB規模。
- [SimpleFileLogHandler.swift](../Sources/AmbeoCore/Utilities/SimpleFileLogHandler.swift) 57行目の `UnsafeMutableRawPointer(bitPattern: …)!` はログ内の force unwrap。`ObjectIdentifier(Thread.current)` で十分。
- 同ファイル4行目の `@_silgen_name("swift_demangle")` はランタイム内部依存。`.error` 時のみ発火するので実用は妥当だが、スタックトレース機能をビルドフラグで落とせるようにしておくと安全。
- ad-hoc 署名（[PackageApp.swift](../Scripts/PackageApp.swift) 86 / 91行目の `--sign -`）ゆえ `install.sh` の `tccutil reset` が必要なのは設計として正しい。配布を考えると**自己署名証明書で DR を安定化**すると「再ビルドのたびに権限オフ→オン」が解消する。
- **終了時の音量戻しがミュートを解除する**：`prepareForTermination` → `revertOutstandingBoost` → [AmbeoClient.swift](../Sources/AmbeoCore/Network/AmbeoClient.swift) 411〜420行目 `removeVolumeBoost` が volume を書くため、ミュート中に Quit すると解除される。🔴3 で塞いだ経路の外側なので残した。塞ぐなら「ミュート中は戻さないで台帳に残す」が自然で、復帰後は `isAtmosActive = appliedAtmosBoost > 0`（AppModel.swift）が適用済み状態を復元し、Atmos 終了時または次回再接続時の `revertOutstandingBoost` が回収する。
- `applicationSupportsSecureRestorableState(_:) -> true` 未実装（macOS 14+ で console warning）。

---

## 維持すべき良い点

- **並行処理の作りが丁寧**：`@MainActor` クラスの `Sendable` 準拠、actor 境界、`enqueueAtmosWork` による直列化、`endSession` の独立タスク化（observer 取消で復旧 RPC を殺さない）、`inFlightMute` の扱いなど、典型的なレース条件を潰せている。
- **CoreAudio listener の teardown を別キューへ逃がした対処**（AudioDeviceMonitor.swift 198〜207、256〜265、445〜452行目）は、`Task.cancel()` 側のロックと衝突する既知のデッドロックを正しく回避している。
- `SystemEventMonitor` の tap 無効化（user / timeout）分離と、WindowServer 停止要求をコールバック外へ遅延させる設計は的確。
- `[T](unsafeUninitializedCapacity:)` で取得サイズが縮んだ場合の `initializedCount` 調整（AudioDeviceMonitor.swift 570行目）など、C API の落とし穴を押さえている。
- ログに RPC 所要時間・フェーズ・経過を載せており、実機トラブルの追跡可能性が高い。

---

## 対応順の提案

**対応済み（2026-11-08）**

1. ✅ `NSLocalNetworkUsageDescription` / `NSBonjourServices` 追加（🔴1）
2. ✅ Stealth Rewind のタイムアウト武装タイミング（🔴2）
3. ✅ ミュート中 Boost スキップ（🔴3）
4. ✅ `Stringified` の数値対応＋`Edit` の部分キー耐性（🟡5）
5. ✅ reconcile の自己取消回避（🟡9）
6. ✅ `URLSession` の invalidate（🟡7）＋検出ディスパッチキューの共有（🟡8 アプリ側）

**WON'T FIX（実機仕様・本機実測による）**

- 🔴4 出力ストリーム選択の一般化
- 🟡6 電源断をまたいだ台帳リセット（リセットは二重 Boost＝爆音）

**未対応**

7. 機器側購読キューの解放（🟡8 の残り・実機で API を確定させてから）
8. TCC ポーリング縮小（🟡10）
9. mDNS 応答の妥当性検証（🟡11）
10. `AppModel` 分割でテスト可能域を広げる（🟡12）
11. CI ＋ `Package.resolved` ＋ Tests 整形（🟢）

※ 終了 deadline（🟡13）＋ミュート系の per-request timeout（🟡14）も 2026-11-08 に対応済み。

## 対応記録

| 日付 | 項目 | 状態 |
| --- | --- | --- |
| 2026-11-08 | 🔴1 `Info.plist` の局所ネットワーク系キー | 対応済み（実機でのプロンプト表示は未確認） |
| 2026-11-08 | 🔴2 Stealth Rewind の安全タイムアウト武装 | 対応済み（新規テストで回帰防止。実機検証は未実施） |
| 2026-11-08 | 🔴3 Atmos Boost によるユーザーミュートの解除 | 対応済み（単体テスト無し・実機検証は未実施） |
| 2026-11-08 | 🔴4 出力ストリーム選択の一般化 | **WON'T FIX**（本機6デバイス実測で全て out streams=1。Mac の Atmos は HDMI パススルー時のみで、その経路は常に単一ストリーム。診断ログも入れない） |
| 2026-11-08 | 🟡5 `Stringified` の数値対応 | 対応済み（部分 edit キーの必須化も修正。新規8テストで回帰防止） |
| 2026-11-08 | 🟡6 電源断をまたいだ台帳リセット | **WON'T FIX**（AMBEO は音量を保持するため不整合が起きない。台帳リセットは二重 Boost＝爆音になる。不変条件を明記） |
| 2026-11-08 | 🟡13 終了処理の上限時間 / 🟡14 ミュート系の per-request timeout | 対応済み（Quit 猶予 2.5秒、ミュート系書き込みは 2秒上限。新規テスト1件。実機での Quit 体感は未確認） |
| 2026-11-08 | 🟡9 reconcile の自己取消 | 対応済み（didSet でストリームを再生成しない。単体テスト無し・実機確認は未実施） |
| 2026-11-08 | 🟡7 `URLSession` の invalidate / 🟡8 キュー整理 | 🟡7 対応済み（`shutdown()` 追加・テスト2件）。🟡8 はアプリ側の検出キューのみ対応、**機器側購読キューは解放 API が実機未検証のため未対応** |
| 2026-11-08 | バージョン更新 | `0.1.27` / build `27`（`Info.plist`。`SettingsView.swift` のフォールバック文字列は 🟢 のまま） |

### 2026-11-08 の変更ファイル

- `Sources/AmbeoCompanion/Info.plist` — `NSLocalNetworkUsageDescription` / `NSBonjourServices` / `LSMinimumSystemVersion` を追加
- `Scripts/install.sh` — `tccutil reset LocalNetwork` とヘッダコメントの追記
- `README.md` / `README.ja.md` — 必要な権限に「ローカルネットワーク」（macOS 15+）を追記。Permissions 画面では状態を表示できない旨と、検出失敗時の確認手順を追記
- `Sources/AmbeoCompanion/UI/PermissionOnboardingView.swift` — Local Network 行と `LocalNetworkPermissionStatus`（推定判定の純関数）を追加
- `Sources/AmbeoCompanion/App/AppModel.swift` — `discoveryStartedAt`（検索開始時刻、4行）を追加
- `Sources/AmbeoCompanion/App/MediaKeyPermissions.swift` — `openSystemSettings` → `openPrivacyPane` にリネーム（UI 側から共有）

※ README の「Permissions 画面では状態を表示できない」の記述は UI 追加に伴い、推定表示する旨へ更新済み。

### 🔴2 の変更ファイル
- `Sources/AmbeoCore/Audio/StealthRewindCoordinator.swift` — 安全タイマーをセッション開始直後へ移動、ログ／クラス文書更新、`Phase` を internal 化
- `Tests/AmbeoCoreTests/StealthRewindTests.swift` — `slowMuteRequestEndsSessionAtDeadline` を追加
- `README.md` / `README.ja.md` — 安全タイムアウトの武装タイミングを明記

### 🔴3 の変更ファイル

- `Sources/AmbeoCompanion/App/AppModel.swift` — `setBoostVolume` にミュート関門、`isSoundbarMuted` と `replayDeferredAtmosVolumeWork` を追加、ミュート解除の検知（telemetry / メディアキー）を配線
- `README.md` / `README.ja.md` — ミュート中は適用せず解除時に適用される旨を明記

### 🟡5 の変更ファイル

- `Sources/AmbeoCore/Network/AmbeoModels.swift` — `Stringified` が文字列 / Int / Double（整数値は正規化）/ Bool を受け、object・array・null は nil のまま throw しない
- `Sources/AmbeoCore/Network/AmbeoEndpoint.swift` — `Player.Volume.Edit` と `Audio.Preset.Edit` を `decodeIfPresent` ベースの tolerant な `init(from:)` に変更（部分キーでエントリー全体が失敗するのを解消）
- `Tests/AmbeoCoreTests/StringifiedDecodingTests.swift` — 新規（8テスト）

### 🟡13・🟡14 の変更ファイル

- `Sources/AmbeoCore/Network/AmbeoClient.swift` — `interactiveTimeout = 2.0` と per-request timeout 引数（`set` / `getEntry` / `getValue` / `fetchDirectValue` / `removeVolumeBoost`）
- `Sources/AmbeoCompanion/App/AmbeoCompanionApp.swift` — `terminationGrace = 2.5秒` のタスクグループで `prepareForTermination()` を競わせ、超過時はログして Quit を進める
- `Sources/AmbeoCompanion/App/AppModel.swift` — ミュート系・Boost 系・スリープ前戻し・`removeVolumeBoost` に 2秒上限を適用
- `Tests/AmbeoCoreTests/AmbeoClientTimeoutTests.swift` — 新規（ハング応答で per-request timeout が効くことを確認）
- `README.md` / `README.ja.md` — Mute / Mute 解除要求の 2秒上限を明記

### 🟡9 の変更ファイル

- `Sources/AmbeoCompanion/App/AppModel.swift` — `settings.audioDeviceUid` の didSet で `startMonitoringAudioDevice()` を呼ばなくなり、`updateFormatMonitoringForActiveDevice()` ＋条件付き `applyFallbackFormatIfNeeded` ＋ `restartSystemEventMonitorIfNeeded()` に置換（8行追加）

### 🟡7・🟡8 の変更ファイル

- `Sources/AmbeoCore/Network/AmbeoClient.swift` — `shutdown()`（`finishTasksAndInvalidate` ＋ `isShutDown`）、`set` / `fetchDirectValue` / `startObserving` の使用済みクライアント保護
- `Sources/AmbeoCompanion/App/AppModel.swift` — クライアントを破棄する4経路（再接続・世代古化・スリープ・終了）で `shutdown()` を呼ぶように変更
- `Sources/AmbeoCore/Network/SennheiserDiscovery.swift` — `browse()` ごとに新設していた DispatchQueue を共有 static に
- `Tests/AmbeoCoreTests/AmbeoClientShutdownTests.swift` — 新規（2テスト）。`AmbeoClientTimeoutTests` のハングスタブを共有

次の対応推奨は 🟡10（TCC 権限ポーリングの縮小）。🔴4 と 🟡6 は実機仕様により WON'T FIX（上記）。
