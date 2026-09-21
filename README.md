# Ambeo Companion

Sennheiser AMBEO Soundbar (Mini / Plus / Max) を macOS 上から快適に操作・連携するためのコンパニオンメニューバーアプリケーションです。

macOS の eARC / HDMI パススルー環境における音量調整の制約を解消し、キーボードのメディアキー連携、Dolby Atmos 音量自動補正、macOS ネイティブ風の OSD 表示、グローバルショートカット機能などを提供します。

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
- **グローバルショートカット**:
  - 自由なキーバインドを登録し、いつでも以下の機能をワンキーで操作可能です：
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

---

## 必要な権限とセキュリティ設定

### 1. アクセシビリティ権限（メディアキー連動に必須）
Magic Keyboard や Mac の音量キー（メディアキー）を `CGEventTap` によりインターセプトして AMBEO サウンドバーへ転送するため、macOS の **アクセシビリティ権限** が必要です。

1. **初回起動時**:
   - macOS の **「システム設定 > プライバシーとセキュリティ > アクセシビリティ」** を開きます。
   - リスト内にある **AmbeoCompanion**（または **Ambeo Companion**）のスイッチを **ON** にします。
   - リストに表示されていない場合は、左下の「+」ボタンから `/Applications/AmbeoCompanion.app` を追加してください。

2. **アプリ更新時・再ビルド時の注意（音が動かない場合の対処法）**:
   - アドホック署名されたアプリのバイナリが更新されると、macOS のセキュリティ機構（TCC）がコード署名のチェックサム不一致を検知し、**設定画面で「ON」と表示されていても内部的に権限が無効化される**ことがあります。
   - **メディアキーのフックが効かない場合**:
     - 「システム設定 > プライバシーとセキュリティ > アクセシビリティ」で一度 **OFF にしてから再度 ON** に切り替えてください。
     - または、リストから AmbeoCompanion を `-` で削除し、再度 `+` で追加してください。

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
