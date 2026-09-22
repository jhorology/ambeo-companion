# Ambeo Companion

Sennheiser AMBEO Soundbar (Mini / Plus / Max) を macOS 上から快適に操作・連携するためのコンパニオンメニューバーアプリケーションです。

macOS の eARC / HDMI パススルー環境における音量調整の制約を解消し、キーボードのメディアキー連携、Dolby Atmos 音量自動補正、無音放置時の自動スリープ（Eco Standby）制御・強制覚醒、macOS ネイティブ風の OSD 表示、グローバルショートカット機能などを提供します。

---

## 主な機能（機能概略）

- **メディアキー連動・音量同期**:
  - Apple Magic Keyboard や Mac の音量キー（音量アップ、音量ダウン、消音）をインターセプトし、eARC 経由では操作できない AMBEO サウンドバーの本体音量とリアルタイムに同期します。
- **macOS ネイティブ風 HUD / OSD (On-Screen Display)**:
  - 音量変更や各種モード切替時に、macOS 標準のボリュームインジケータに似た HUD を画面上に表示します。
  - 実機リモコン、本体ボタン、Web UI など外部からの操作もロングポーリングによりリアルタイム検知し、OSD に即座に反映します。
  - フロント LED 風の AMBEO ロゴ、Night Mode（実機準拠のパープル LED）、Voice Enhancement、Eco モード、オートスタンバイ、電源状態をグラフィカルに表示します。
  - マルチディスプレイ環境でもアクティブな画面にスムーズに追従し、滑らかなフェードアニメーションを実現しています。
- **Atmos Boost (Dolby Atmos 自動音量補正)**:
  - Dolby Atmos（空間オーディオ）とステレオ PCM 音源が混在するプレイリスト再生時、音源切り替えに伴う音量差を自動で解消するため、Atmos 再生時に指定した音量（0〜40%）を自動でブーストします。
- **Fallback Audio Format 制御**:
  - Dolby Atmos 非再生時に macOS が 192 kHz にデフォルト化して不要な処理負荷や遅延が生じるのを防ぎ、指定したフォーマット（48 kHz 2ch など）へ自動フォールバックします。
- **Auto Standby 制御 & 自動同期（無音スリープ問題の根本解消）**:
  - 公式 Smart Control アプリや Web UI では規制（EU ErP指令等）により隠されている「オートスタンバイ待機時間（Off / 5分 / 10分 / 15分 / 30分）」を設定画面から直接変更可能です。
  - PC 環境で「音声をしばらく再生しないとサウンドバーが勝手にエコモードに入り、HDMI/eARC 経由で音が出なくなる」問題を「Off (Never)」設定により根本解決します。
  - アプリ側の設定として永続化されるため、サウンドバー本体の電源オフやファームウェア更新等で実機側の待機時間がリセットされた場合でも、アプリ起動時・再接続時に希望の設定値へ自動で強制同期（上書き適用）します。
- **Wake Up Soundbar（ワンクリック & ワンキー強制覚醒）**:
  - サウンドバーがスリープ（Eco Standby）に入って HDMI/eARC オーディオリンクが切断された場合でも、メニューバーの「Wake Up Soundbar」メニュー、または割り当てたグローバルショートカットからワンアクションでサウンドバーを即座に強制覚醒させ、HDMI TV 音声を即復帰させます。
  - AirPlay への切り替えと HDMI への戻しといった手動のワークアラウンドが不要になります。
- **グローバルショートカット**:
  - 自由なキーバインドを登録し、いつでも以下の機能をワンキーで操作可能です：
    - Wake Up Soundbar (スタンバイからの即時強制覚醒・HDMI復帰)
    - AMBEO 3D Mode 切替 (On / Off)
    - AMBEO 3D Level 切替 (Light / Standard / Boost)
    - 音声プリセット切替 (Adaptive, Music, Movie, News, Neutral, Sports)
    - Night Mode 切替 (On / Off)
    - Voice Enhancement 切替 (On / Off)


- **ログイン時自動起動 (Launch at Login)**:
  - macOS 13+ の `ServiceManagement` (`SMAppService.mainApp`) に完全準拠し、設定画面からワンクリックで Mac 起動時のバックグラウンド常駐を有効化できます。
- **mDNS デバイス自動検出**:
  - ローカルネットワーク上の AMBEO サウンドバーを自動検出し、IP アドレスの指定なしですぐに接続可能です。

---

## 動作要件

- **OS**: macOS 14.0 (Sonoma) 以降
- **Swift / Xcode**: Swift 6.0+ / Xcode 16+
- **対象機器**: Sennheiser AMBEO Soundbar Mini / Plus / Max

---

## ビルド & パッケージング手順

### 1. 開発ビルド (Debug)
SPM (Swift Package Manager) を使用してビルドします。

```bash
swift build
```

### 2. リリースバイナリのビルド
```bash
swift build -c release --product AmbeoCompanion
```

### 3. macOS アプリバンドル (`AmbeoCompanion.app`) のパッケージング
付属のパッケージスクリプトを実行することで、Release ビルドのコンパイル、リソース同梱、アドホックコード署名までを自動で行います。

```bash
swift Scripts/PackageApp.swift
```

スクリプトが実行する処理内容：
1. `swift build -c release --product AmbeoCompanion` で最適化バイナリをビルド
2. `AmbeoCompanion.app` の標準バンドル構造 (`Contents/MacOS`, `Contents/Resources`) を生成
3. 実行ファイル、`Info.plist`、アプリアイコン (`AppIcon.icns`)、依存パッケージリソース (`KeyboardShortcuts_KeyboardShortcuts.bundle`) を配置
4. `codesign --deep --force --options runtime --sign - AmbeoCompanion.app` によるアドホックコード署名

### 4. アプリの起動
生成されたアプリバンドルは以下で直接起動できます：

```bash
open AmbeoCompanion.app
```

### 5. `/Applications` へのインストール
ビルド、署名、`/Applications/AmbeoCompanion.app` へのコピー、そして再署名で無効になる権限の再登録は次のスクリプトが行います。

```bash
Scripts/install.sh
```

メディアキーの取得は **アクセシビリティ**（イベントを消費する event tap）と **入力監視**（キーの観測）の両方が必要です。スクリプトは両方の TCC 登録をリセットし、システム設定を順番に開きます。スイッチをオンにする操作自体は macOS がスクリプトに許可しないため、表示された画面でオンにし直してください。

---

## 必要な権限とセキュリティ設定

### 1. アクセシビリティと入力監視（メディアキー連動に必須）
Magic Keyboard や Mac の音量キーを `CGEventTap` で受け取り、イベントを消費して AMBEO サウンドバーへ転送します。これには次の両方が必要です。

- **システム設定 > プライバシーとセキュリティ > アクセシビリティ**
- **システム設定 > プライバシーとセキュリティ > 入力監視**

リストに無い場合は「+」から `/Applications/AmbeoCompanion.app` を追加し、スイッチをオンにします。

再ビルドのたびにアドホック署名のチェックサムが変わるため、画面上はオンのままでも権限が無効になります。`Scripts/install.sh` が両方の登録をリセットし、設定画面を順に開きます。メディアキーが効かないときは、そのスクリプトを実行するか、各画面で一度オフにしてからオンにし直してください。

### 2. Gatekeeper（開発元未確認の警告が出る場合）
GitHub Releases 等からダウンロードした `.app` を起動する際、「開発元を検証できないため開けません」等の警告が出る場合があります。

- **対処法 1**: Finder で `AmbeoCompanion.app` を **右クリック ＞「開く」** を選択し、ダイアログで「開く」をクリックします。
- **対処法 2**: ターミナルで隔離属性（Quarantine）を解除します：
  ```bash
  xattr -cr /Applications/AmbeoCompanion.app
  ```

---

## アイコンの再生成 (任意)

アプリアイコンを変更・再生成する場合は、ベクター描画スクリプトを実行すると 1024x1024 PNG から multi-resolution な `.icns` が自動生成されます。

```bash
swift Scripts/GenerateAppIcon.swift
```

---

## ライセンス

[MIT License](LICENSE)
