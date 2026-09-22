# wipe-disk — 廃棄用 HDD の完全消去

[English README](README.md)

USB ドック（KURO-DACHI など）に挿した磁気 HDD を、廃棄前に**全セクタゼロ上書き → 読み戻し検証**するツール。

- 方式: `diskpart clean all`（全論理セクタに 0x00 を 1 回書く）。NIST SP 800-88 Rev.2（2025-09、Rev.1 を置換）§3.1.1 の Clear（overwrite）に該当。
  規格は「上書きは最先端の研究所レベルの手法による復元も通常は妨げる」と記述し、複数回上書きを要求しない
- 検証: 上書き後に `\\.\PhysicalDrive<N>` を生で読み戻し、ゼロであることを機械判定して `VERDICT: PASS / FAILED / UNKNOWN` を出す
- 証明: 1 台ごとに日本語の**消去証明書** `logs\wipe-report-<S/N>-<日時>.txt`（＋ `.json`）を出す。項目は同規格 §4.6 の証明書要件に沿う
- **SSD には使わない**（ゼロ上書きは SSD の消去保証にならない。スクリプトも MediaType=SSD を拒否する）
- 元に戻す手段は無い。既定はドライラン

## 使い方（エクスプローラでダブルクリック）

`wipe-disk.cmd` をダブルクリックすると、対話形式（英語）で進む:

1. UAC が出るので「はい」 → 管理者のウィンドウが開く
2. ディスク一覧が出る（`Number / Model / BusType / IsBoot / IsSystem / SizeGB`）
3. `Disk number to wipe:` に番号を入力（Enter だけなら何もせず終了）
4. 対象の型番・容量・消えるパーティション一覧が表示され、ガードを通ると HDD 本体のシリアルを取得する。
   smartctl が無い（または USB ドックが通さない）場合は
   `Type the serial number printed on the drive label` → **外装ラベルの S/N を入力**（証明書に「手入力」と記録される。Enter で省略可）
5. `Type the disk model exactly as shown above` → 表示された型番をそのまま入力（空白・大文字小文字は無視）
6. `Type WIPE (upper case) to start` → `WIPE` を入力 → 上書き開始
7. 完了後に**全セクタ**を読み戻して検証 → `VERDICT` と `Result:` が出る。`PASS` なら廃棄可
8. `logs\wipe-report-<S/N>-<日時>.txt` に消去証明書（日本語）が出る。印刷して手書き欄（氏名・資産番号・署名）を埋める

6 の `WIPE` まで何も書かないので、途中でやめるなら Ctrl+C か、型番以外を入力すればよい。

コマンドプロンプトからの引数（任意）:

```
wipe-disk.cmd 3                    Disk 3 を選択済みで開始
wipe-disk.cmd 3 ST500DM002         型番に ST500DM002 を含むことも要求する
wipe-disk.cmd 3 /quick             読み戻しを 64 か所サンプルにする（全セクタは既定）
wipe-disk.cmd 3 /dryrun            何をするか表示するだけ（書かない）
wipe-disk.cmd 3 /verifyonly        読み戻しだけ行う（書かない）
wipe-disk.cmd /verifyonly          同上。ディスク番号は対話で聞く
```

フラグはどの位置に書いてもよい。フラグでない最初の引数がディスク番号、2 つ目が型番（`3 "" /quick` も従来どおり通る）。
フラグでも数字でもない引数は PowerShell を呼ぶ前に拒否する。

所要時間の目安: 500 GB HDD で USB 3 なら上書き 1〜2 時間（実測 77 分 / 107 MB/s）＋全セクタ読み戻し 1〜2 時間。USB 2 なら各 4〜5 時間。途中でドックの電源や USB を触らない。

完了後に Windows が「ディスクの初期化」を出したらキャンセルし、ドックの電源を切って外す。

## ガード（1 つでも該当すると何もしない）

- ブート / システムディスク
- USB バス以外（内蔵ディスクを誤って消さないため）
- MediaType が SSD
- このスクリプト・`%TEMP%`・SystemDrive が対象ディスク上にある
- 型番が `ExpectModel` の指定と一致しない

## 消去証明書（会社提出用）

`-Apply` / `-VerifyOnly` の実行ごとに `logs\wipe-report-<S/N>-<日時>.txt`（日本語、UTF-8 BOM）と同名 `.json` を出す。
文面は `report.ja.txt`（テンプレート。先頭の `@key=値` は可変文言の辞書）にあり、スクリプト本体は ASCII のまま。

記載項目（NIST SP 800-88 Rev.2 §4.6 の証明書要件に対応）:

| 節 | 内容 |
|---|---|
| 1 媒体情報 | 型番・**S/N と取得元**・ファームウェア・WWN・容量/セクタ数/LBA 範囲・接続（ブリッジ S/N）・消去前のパーティション一覧。資産番号と出所は手書き欄 |
| 2 実施情報 | Windows アカウント・PC 名/OS ビルド・ツールとバージョン（Wipe-Disk.ps1、DiskPart、シリアル取得手段）・ログと JSON のパス。氏名/役職/場所/連絡先は手書き欄 |
| 3 消去方法 | Clear（§3.1.1）/ Overwrite 0x00 × 1 回（`diskpart clean all`）・開始/終了時刻・所要時間・実効速度・DiskPart の終了コードと出力・上書き後の状態 |
| 4 検証 | 生デバイス読み戻しの方法・範囲（全セクタ or サンプル）・読み出しバイト数と秒数・非ゼロ検出数・結果 |
| 5 判定 | PASS / FAILED / UNKNOWN と判定文 |
| 6 根拠と適用範囲 | 規格の引用（§3.1.1・§4.5.1・§4.6）と、対象（磁気 HDD、OS から見える全論理セクタ）の明記 |
| 7-8 | 処分のチェック欄（廃棄 / 社内再利用 / その他）、実施者・確認者の署名欄 |

**S/N の取得元**（証明書に必ず明記される）:

1. `smartctl`（smartmontools）があれば、USB ドック越しに HDD 本体の ATA IDENTIFY を読む → ラベルの S/N と一致する値。
   導入: 管理者 PowerShell で `winget install smartmontools.smartmontools`（または `bin\smartctl.exe` を置く）
2. 無ければ実行時にラベルの S/N を手入力 → 「手入力」と記録（`-LabelSerial` で引数指定も可）
3. どちらも無ければ Windows の値（＝ドックのブリッジ S/N）を「ブリッジ側」と明記して記録

証明書は「復元不能」を自ら断定せず、規格の Clear の手順を実施した事実と読み戻し結果を記録する書き方にしている。
社内の安全基準によりソフトウェア消去のみが選択肢であるため、物理破壊・消磁・業者委託に関する文言は意図的に載せていない。

## 注意

- **USB ドック経由の SerialNumber はドック（ブリッジ）のもので、HDD 本体を識別しない。** 別の HDD を挿しても同じ値になる。
  型番と容量で対象を確認すること。ディスク番号は抜き差しで変わることがあるので、毎回ドライランの表示で確かめる
- `logs\wipe-disk<N>-<日時>.log` に、対象・消したパーティション一覧・diskpart の出力・所要時間・検証結果が残る。証明書とともに保管する
- 証明書は 1 回の実行につき 1 通。上書きと検証を別実行に分けると「検証のみ」の証明書になるので、提出用は 1 回で通す

## 直接呼ぶ場合（管理者 PowerShell）

```powershell
.\Wipe-Disk.ps1 -DiskNumber 3 -ExpectModel ST500DM002                 # ドライラン
.\Wipe-Disk.ps1 -DiskNumber 3 -ExpectModel ST500DM002 -Apply          # 上書き + 64 か所サンプル検証
.\Wipe-Disk.ps1 -DiskNumber 3 -ExpectModel ST500DM002 -Apply -FullVerify
.\Wipe-Disk.ps1 -DiskNumber 3 -VerifyOnly -FullVerify                 # 読み戻しのみ
.\Wipe-Disk.ps1 -DiskNumber 3 -Apply -FullVerify -LabelSerial 100924PBB2XXXX -Operator "山田 太郎"
.\Get-DriveIdentity.ps1 -DiskNumber 3                                 # S/N 取得の確認だけ（読み取り専用）
```

終了コード: 0 = PASS / ドライラン、1 = 検証 FAILED または diskpart 失敗、2 = ガードまたは確認で中断（未書き込み）、3 = 検証できず UNKNOWN。

## ファイル

| ファイル | 役割 |
|---|---|
| `wipe-disk.cmd` | 呼び出し用バッチ。昇格 → 一覧 → 番号入力 → `Wipe-Disk.ps1 -Apply -FullVerify`。ASCII のみ |
| `Wipe-Disk.ps1` | 本体。PowerShell 5.1 で動作。ASCII のみ（cp932 で読まれても壊れない） |
| `Get-DriveIdentity.ps1` | HDD 本体の S/N 取得（smartctl 経由、無ければ Windows 値）。読み取り専用。ASCII のみ |
| `report.ja.txt` | 消去証明書の日本語テンプレート（UTF-8）。文言を変えるときはここだけ |
| `logs\` | 実施記録（ログ・証明書 txt/json） |
| `tests\verify-test.ps1` | 読み戻し判定・VERDICT・スリープ抑止・証明書描画の単体テスト（ファイルで代用。昇格不要、25 項目） |

実行中は `SetThreadExecutionState` で PC のスリープを抑止する（プロセス終了で解除。電源設定は変えない）。

## 実績

- 2026-09-19: Disk 3 = Seagate ST500DM002（465.76 GB、KURO-DACHI / USB 3）。`clean all` 4,652 秒（107 MB/s）、64 か所読み戻し全ゼロ、PASS。`logs\wipe-disk3-20260919-085747.log`
- 2026-09-19: Disk 3 = Hitachi HTS545016B9A300（149.05 GB、2.5 インチ）。`clean all` 3,242 秒（47 MB/s）は exit 0。
  直後の全セクタ読み戻しがスクリプトのバグ（下記）で UNKNOWN → 修正後に `/verifyonly` で再検証。`logs\wipe-disk3-20260919-130537.log`

## 保守の注意

- `wipe-disk.cmd` の `if ( ... )` ブロック内の `echo` に括弧 `( )` を書かない（`)` でブロックが閉じて、以降の行が無条件に実行される。2026-09-19 に実際に踏んだ）
- PowerShell の `-f` の引数に割り算を書くときは必ず括弧で囲む。`"{2}" -f $a, $b / 1GB, $c` は `,` が `/` より強く結合し、
  `-f` に 2 引数しか渡らず実行時エラーになる（2026-09-19 に全セクタ検証が UNKNOWN になった原因）
- `.cmd` で `if <条件> set "X=1" & goto :eof` と書くと、**条件が偽でも `goto` が走る**（`&` は `if` の評価より前にコマンドを切る）。
  括弧で囲んだブロックにして、判定ごとに 1 ブロックにする
- `0x80000000` のような 16 進リテラルは int32 の負数になる。`[uint32]2147483648` と 10 進で書く
- **ドットソース（`. .\Get-DriveIdentity.ps1`）は、相手の `param()` を自分のスコープで実行する。**
  同名の変数（`$DiskNumber`）が相手の既定値 `-1` で上書きされ、直後の `Get-Disk -Number -1` で止まった（2026-09-22、-Apply 実行時。
  ディスクには未書き込み）。呼ぶ側で退避・復元する（`Wipe-Disk.ps1` の「drive identity」節）
- IOCTL_ATA_PASS_THROUGH / SCSI ATA PASS-THROUGH を P/Invoke で直接送る実装は、管理者でも Win32 error 5 で失敗した
  （2026-09-19、内蔵 SATA でも USB でも）。原因未特定のまま残さず削除し、smartctl に任せている。再挑戦するなら原因を先に切り分ける
- 判定ロジックを変えたら `tests\verify-test.ps1`（fails=0）と、ドライラン、「Disk 1（システム SSD）を渡して拒否されること」を確かめる
