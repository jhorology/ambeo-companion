# macOSの常時Dolby MAT出力に関する調査

調査日: 2026-10-14（JST）

## 目的と結論

Ambeo Companionの将来機能として、macOSの通常音声・通知音・Atmos再生を、Apple TV実機のように常時Dolby MAT接続で出力できるかを調べた。

**現時点で、再現性のある公開ハックや、Macの通常PCMをMAT 2.xへ変換できる利用可能な入口は特定できていない。** ただし、接続先のEDIDとmacOSのHDMI音声ドライバにはMAT対応の手掛かりがある。ハードウェア的に不可能とは判断できない。

今回のMusic.app／TV.appのAtmos再生は、E-AC-3 Atmosのパススルーだった。MAT系形式は対応一覧に存在するが、実際に選択・送信された記録はない。

追加調査は「macOS内に呼び出せるMAT生成処理が存在するか」に半日〜1日程度絞る価値がある。自前MATエンコーダ開発やtvOSバイナリ移植が必要になる場合、アプリの追加機能としては負担が大きく、一旦保留が妥当と評価した。

## 調査環境・操作範囲

- macOS 27.0.1、Build 26A434。
- ローカルSDK: Xcode 27.0.0のMacOSX SDK。
- HDMI音声デバイス名: `AW3225QF`。
- 観測時のCoreAudio Device ID: 96、Stream ID: 97。IDは再接続等で変わり得る。
- 対象アプリ: Music.app、TV.app。
- 想定接続: Mac → AW3225QF → eARC → AMBEO。今回、受信側AMBEOの実コーデックは照合していない。
- アプリの再生／ポーズ、音声選択、パススルー設定変更はユーザーが実施。
- 調査側はIORegistry・CoreAudio・ログ・登録情報・バイナリを読み取り、使い捨てのSwiftプローブでコーデック／変換器を作成・破棄した。
- HDMI形式変更、排他取得、音声送信、再生中プロセスの改変、システムバイナリの改変は実施していない。
- 原ログの全量は保存していない。この文書のログ抜粋と数値は、セッション中に取得したツール出力に基づく。メモリアドレス等は省略した。

## 用語の整理

| 用語 | 本調査での意味 |
|---|---|
| Dolby Atmos | オブジェクト音声を含む方式。表示名だけでは伝送形式を判別できない |
| E-AC-3 / Dolby Digital Plus | 圧縮音声コーデック。JOC拡張によってAtmosを運べる |
| Dolby MAT 2.x | PCM音声とAtmosメタデータ等を伝送する方式 |
| E-AC-3 Atmosパススルー | 圧縮音声を受信側へ送り、受信側でデコードする経路 |
| 常時MAT接続 | 元音声の形式が変わってもMAT接続を維持すること。常に元音源がAtmosという意味ではない |

Apple TV実機のContinuous Audio Connectionは、MAT接続を維持して音声形式切り替え時の途切れを防ぐ公式機能。MacのHDMIパススルーは、元のAC-3／E-AC-3／E-AC-3 JOCビットストリームを送る機能として説明されており、同一の機能ではない。[Apple TV公式説明][apple-tv]、[Mac公式説明][mac-passthrough]、[Dolby技術資料][dolby-mat]

E-AC-3入力が存在するだけではMAT出力を否定できない。デコード後にMATへ変換する構成もある。今回は入力名に加え、現在のHDMI形式とドライバのリンク形式を確認して区別した。

## 実機の再生状態

| 条件・取得時刻（JST） | 現在のHDMI形式 | 稼働 | 排他所有者 | その他の証拠 |
|---|---|---|---|---|
| Music、Atmos曲ポーズ中 | LPCM 48 kHz、2ch、24bit | 停止 | -1（なし） | 直近ログにAtmosパススルー処理が残る |
| Music、Atmos曲再生中、13:02台の処理を観測 | `cc+3` 192 kHz、2ch、16bit | 稼働 | Music PID 4498 | リンク形式 `Dolby Atmos (EAC3)` |
| TV起動後、13:06:03取得 | LPCM 48 kHz、2ch、24bit | 停止 | -1 | 13:05:00にTVのAtmosパススルー初期化ログ |
| TV、Atmos作品再生中、13:07:22取得 | `cc+3` 192 kHz、2ch、16bit | 稼働 | TV PID 6780 | リンク形式 `Dolby Atmos (EAC3)` |
| TV、パススルーOFF、13:15:47取得 | LPCM 48 kHz、2ch、24bit | 稼働 | -1 | 選択音声はステレオAAC。後述の制約あり |
| TV、オリジナル音声・パススルーON、13:19:20取得 | `cc+3` 192 kHz、2ch、16bit | 稼働 | TV PID 6780 | `audio-atmos` / `ec-3`の選択とリンク形式を照合 |

符号化形式の「2ch・192 kHz」は伝送用の表現であり、ステレオへダウンミックスされたことや元音源のサンプルレートを意味しない。

### オリジナル音声・パススルーONのTVログ

13:17:20の再生選択ログ:

```text
AudioGroup: audio-atmos_vod-ap-amt.tv.apple.com
Codecs: ec-3, hvc1...
desiredRate: 1.0
```

13:17:54の音声処理ログ:

```text
ACCPEDecoderWrapper
Input:  qc+3, 16 ch, 192000 Hz
Output: cc+3, 2 ch, 192000 Hz

ACDDPAtmosPassThroughDecoder
mIsAtmos = 1, mIsTVOS = 0
Input:  ec+3, 16 ch, 192000 Hz
Output: cc+3, 2 ch, 192000 Hz
        16 bits/channel, 24576 bytes/packet, 6144 frames/packet
```

IORegistryのリンク開始記録:

```text
Command: StartLink
CommandStatus: success
Format: Dolby Atmos (EAC3)
LinkSampleRate: 192000
ChannelCount: 2
SampleSize: 16
```

MacからのE-AC-3 Atmos送信を裏付ける。モニターが変換せずeARCへ中継していれば、デコード・AtmosレンダリングはAMBEO側になる。ただし、AMBEO側の受信情報を未確認のため、モニター以降で変換がないことは未確定。

### パススルーOFF実験の重要な制約

13:14:53のログではAAC 2ch → Float32 PCM 2chのデコード、13:14:55の再生選択ログでは `audio-stereo-160` / `mp4a.40.2` が記録された。

その後ユーザーから、以前の再生はオリジナル音声ではなかったとの補足があった。このOFF実験ではステレオ音声が選択されていたため、**オリジナルのAtmos音声をOFFでデコードした場合の検証にはなっていない。**

「OFFでは必ずステレオになる」「MacにはAtmosをデコードする経路がない」「OFFでもMATへ入らない」と一般化してはいけない。オリジナル音声を選択したOFF条件は再検証候補。

## IORegistryとCoreAudio

### ドライバ接続

```text
DCPAVAudioInterfaceProxy
  └─ DCPAVAudioDriver
```

ドライバの発行元は `com.apple.driver.DCPAVFamilyProxy`。`IOUserClientClass`には `DCPAVAudioInterfaceProxyUserClient` が存在した。

`output streams → available formats`には次の符号化形式があり、CoreAudioから取得した対応形式とも一致した。

| FourCC | 伝送レート | bytes/packet | frames/packet | bytes/frame |
|---|---:|---:|---:|---:|
| `mtct` | 768000 | 61440 | 15360 | 4 |
| `mtc+` | 768000 | 61440 | 15360 | 4 |
| `cec3` / `cc+3` / `cd+3` | 192000等 | 24576 | 6144 | 4 |

各形式は2ch・16bit、ドライバ側のformat flagsは76。`mtct`／`mtc+`は本アプリがMAT系として扱う非公開FourCCであり、今回のSDKに公開されたMAT定数や正式名称を確認できたわけではない。

`kAudioStreamPropertyPhysicalFormat`は `AudioObjectIsPropertySettable` で書き込み可能と報告された。しかし、個々の形式への変更成功・データ送信・受信成功は未検証。書き込み可能フラグだけで送信できるとは判断しない。

今回のDCPドライバのIORegistry内ではサンプルレートが固定小数点値であり、`2^32`で割るとHzと一致した。この解釈を他のプロパティやドライバへ無条件に適用しない。

### 再観測用コマンド

以下はいずれも読み取り。プロセスIDやログの時刻は取得ごとに確認する。

```sh
ioreg -r -c DCPAVAudioDriver -l -w 0
ioreg -r -c DCPAVAudioInterfaceProxy -l -w 0
pgrep -x TV
pgrep -x Music
/usr/bin/log show --last 3m --style compact --predicate \
  'process == "TV" AND (eventMessage CONTAINS[c] "Atmos" OR eventMessage CONTAINS[c] "mtct" OR eventMessage CONTAINS[c] "mtc+")'
```

IORegistryの `EventLog` は履歴を含む。履歴にAtmosがあるだけでは現在の送信状態を示さない。`current format`、`is running`、`exclusive access owner`と最新ログを照合する。

## EDID

Macが取得している384-byte EDIDのCTA音声記述を解析した。

- LPCM: 最大8chまでの記述、32〜192 kHz、16／20／24bitの対応ビット。
- E-AC-3: SAD `57 07 03`。
- MAT/MLP: SAD **`67 54 07`**、最大8ch、48／96／192 kHz。
- MAT/MLPの第3byte `0x07` は、[edid-decode実装][edid-decode]によれば、TrueHDだけでなくオブジェクト音声PCM・チャンネル音声PCMへの対応を示す。該当ハッシュ計算を要求しないビットも設定されている。

これはMacが見ている対応広告であり、実際のサウンドバーまでの受信成功を保証するものではない。ただし、MAT対応広告がすでにあるため、単にEDIDへMAT対応を追加する案の優先度は低い。

LLDVの有効化と同様に潜在的な出力経路を探す発想は有用だが、EDID変更はMATデータ生成器を追加しない。[BetterDisplayのEDID説明][betterdisplay-edid]

## Apple音声コンポーネントの調査

対象:

```text
/System/Library/Components/AudioCodecs.component/Contents/Info.plist
/System/Library/Components/AudioCodecs.component/Contents/MacOS/AudioCodecs
```

登録情報、`strings`、`nm`から以下を確認した。

```text
ACDDPAtmosDecoder.cpp
ACDDPAtmosPassThroughDecoder.cpp
ACAtmosCPEPassThroughDecoderWrapperFactory
ACDDPPassThroughDecoderFactory
```

`Apple PC+3 / QC+3 / ZC+3 Transcoder`の登録説明は、保護されたAtmosをCEC-3 Atmosへ変換する処理。Factory関数が存在すること自体はPCM→MAT変換の証拠ではない。

### 登録済みコーデックの能力問い合わせ

Apple製の `acdc`／`adec`／`aenc` コンポーネントを列挙し、作成可能なインスタンスへ `kAudioCodecPropertySupportedInputFormats`／`SupportedOutputFormats` を問い合わせ、破棄した。音声データは送っていない。

| コンポーネント | 対応入力 | 対応出力 |
|---|---|---|
| PAC3 / QAC3 / ZAC3 Transcoder | `ac-3` | `cac3` |
| PC+3 / QC+3 / ZC+3 Transcoder | `ec+3` | `cc+3` |
| PEC3 / QEC3 / ZEC3 Transcoder | `ec-3` | `cac3`, `cec3` |

この問い合わせでMAT系出力を返すコーデックは見つからなかった。登録されていない内部処理や、別の初期化条件で有効になる処理まで存在しないと証明したものではない。

TVのログでも、そのAtmos入力に対する出力候補5種類はすべて `cc+3` で、パケット長が異なる候補だった。

### AudioConverterの作成試験

ドライバが列挙したMAT系出力記述を使って `AudioConverterNew` を試した。

| 入力 | 出力 | 結果 |
|---|---|---|
| 48 kHz Float32 PCM、2／6／8／16ch | `mtct` / `mtc+` | 全て `1718449215` (`fmt?`) |
| E-AC-3、48 kHz、6ch | `mtct` / `mtc+` | `fmt?` |
| `ec+3`、192 kHz、16ch | `mtct` / `mtc+` | `fmt?` |

出力記述: 768 kHz、2ch、16bit、flags 76、61440 bytes/packet、15360 frames/packet、4 bytes/frame。

`AudioFormatGetProperty(FormatName)`もこのMAT系記述に対して `fmt?` を返した。

これらは特定の記述での変換器作成試験であり、圧縮音声のMagic Cookie、非公開設定、権限等を含む全条件の探索ではない。公開変換器から簡単に利用できる経路が見つからなかった、という限定的な結果。

## `mIsTVOS`分岐の静的調査

`AudioCodecs`はx86_64、x86_64h、arm64e、arm64e.x1のユニバーサルバイナリ。**arm64eスライス**を一時ディレクトリへ抽出し、`nm`と`llvm-objdump`で `ACDDPAtmosPassThroughDecoder` を調べた。原本と実行中プロセスは変更していない。実行時にロードされるスライスとの完全な同一性は確認していない。

ログ出力の引数と読み出し位置を照合すると、オフセット `0xa8` が `mIsAtmos`、`0xa9` が `mIsTVOS` に対応する。

- Atmosサブタイプの初期化では16bit値 `1` を `0xa8` へ書く。little endianでは `mIsAtmos=1`、`mIsTVOS=0` に相当。
- 別の初期化分岐では両方をゼロにする。
- `mIsTVOS`を参照する分岐が残っている。
- trueの場合、形式構築用の集合に16ch候補を追加する。
- `NumAtmosFormatLists()`と形式リスト返却にも影響する。
- 調べた範囲では、設定用プロパティからこの値をtrueへ切り替える入口は見つからない。

**この分岐はMAT生成を有効化するスイッチとは確認できていない。** 内部の16ch形式はそのままMATを意味しない。値を強制変更する実験は行っていない。

## MAT実送信試験の到達点

③「有効なMATデータをドライバへ送れるか」は、次の段階を分けて検証する必要がある。

1. MAT形式への変更をドライバが受け付ける。
2. 有効なMATデータを継続送信できる。
3. 受信側AMBEOがMATとして認識・再生する。
4. 通常のMac音声をMATへ変換し、継続送信する。

対応形式の列挙と書き込み可能フラグまでは確認したが、**1〜3の実送信試験は未実施**。既知の正しいMAT 2.xデータや利用可能な生成器を確保できていない。形式だけの変更、ゼロ埋めデータの送信は受信成功を証明できない。

1〜3に成功しても、常時MAT化には4が別途必要になる。

FFmpegの `spdifenc.c` にあるMAT処理はTrueHDフレームの格納処理であり、目的とするPCM＋メタデータのMAT 2.x生成器と同一視しない。[FFmpeg実装][ffmpeg-mat]

公開実装候補として見つかったSpatialAudioLabは、Windows・Dolby Access等による既存MAT経路のキャプチャ／レンダリング研究で、Mac向けMAT生成器ではない。[SpatialAudioLab][spatial-lab]

`raress96/dolby-atmos-encoder`はE-AC-3 JOCを生成するPoCで、MAT生成器ではない。READMEでも、ソフトウェア解析ではAtmosとして認識される一方、Dolby認証ハードウェアではAtmos動作しないと報告されており、今回の送信試験の既知の正しいMAT入力には使えない。[プロジェクト説明][atmos-encoder]

## アプリへの影響と次の候補

### 現状コードとの関係

- `Sources/AmbeoCore/Audio/AudioDeviceMonitor.swift` は `mtct`／`mtc+` 等を符号化サラウンドとして扱う。
- `supportedFormats(for:)` はLPCM以外を除外するため、設定UIのFallback候補一覧はドライバの全形式一覧ではない。
- Atmos判定は多チャンネル／符号化形式とサウンドバー側の判定を利用する。常時MATを実装する場合は、**伝送形式がMATであることと、元音源がAtmosであることを分離する必要がある**。
- 常時MATで形式切り替えの途切れが減る可能性はあるが、Atmosとステレオの音量差が解消するとは未確認。Atmos Boostを不要にできるとは判断しない。

### 次に進めるなら

1. オリジナルAtmos音声でパススルーOFFを再観測し、選択音声グループ・デコーダ・HDMI形式を照合する。
2. AudioToolboxCore、MediaToolbox等の内部処理や別コーデックに、MAT生成・出力指定の入口があるかを限定的に調べる。
3. 利用可能な生成器／検証済みMAT 2.x入力が得られた場合に、独立した実験プログラムで送信と受信の双方を検証する。
4. 成功後に通常PCMの取り込み・混合、Atmosメタデータ保持、排他制御、ポーズ・無音・再接続の動作を検討する。

探索を続けても生成処理の入口が見つからない場合、通常機能の開発から切り離して保留する。今回の結果はOS 27.0.1と観測した接続条件に限定され、他のMac・OS・接続機器での一般的な不可能性を示すものではない。

## 参照資料

- [Apple TVのContinuous Audio Connection][apple-tv]
- [MacのHDMIパススルー][mac-passthrough]
- [Dolby Atmos for sound bar applications][dolby-mat]
- [BetterDisplayのEDID説明][betterdisplay-edid]
- [edid-decodeのCTA解析実装][edid-decode]
- [FFmpegのIEC 61937／TrueHD MAT格納実装][ffmpeg-mat]
- [SpatialAudioLab][spatial-lab]
- [E-AC-3 JOCエンコーダPoC][atmos-encoder]

[apple-tv]: https://support.apple.com/en-ie/102218
[mac-passthrough]: https://support.apple.com/en-au/guide/mac-help/mchle3a1461c/mac
[dolby-mat]: https://professional.dolby.com/siteassets/tv/home/dolby-atmos/dolby-atmos-for-sound-bar-applications.pdf
[betterdisplay-edid]: https://betterdisplay.pro/guide/technical-reference/edid/
[edid-decode]: https://github.com/gjasny/v4l-utils/blob/master/utils/edid-decode/parse-cta-block.cpp
[ffmpeg-mat]: https://github.com/FFmpeg/FFmpeg/blob/master/libavformat/spdifenc.c
[spatial-lab]: https://github.com/barralutz/spatial-audio-lab
[atmos-encoder]: https://github.com/raress96/dolby-atmos-encoder
