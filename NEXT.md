# 次にやること — gjPiP 宣伝ページ（GitHub Pages）

iTerm2 の再起動をまたぐので、ここから再開する。

## いま止まっている理由

**iTerm2 に画面収録権限が無く、GIF が録れない。**

```
$ screencapture -x -R 0,0,200,100 test.png
could not create image from rect      ← これ
```

TCC は「録画しようとしているプロセス」に権限を要求する。私は iTerm2 の下で動いている
（`claude` → `zsh` → `iTermServer-3.6.11` → `/Applications/iTerm.app`）ので、
**iTerm に権限が要る**。gjPiP 側が権限を持っていても関係ない。

### 再開手順

1. System Settings → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音
2. **iTerm** を ON（一覧に無ければ「＋」で `/Applications/iTerm.app` を追加）
3. **iTerm を再起動**（権限は再起動しないと効かない）
4. 再開したら、まずこれで権限を確認する:

```sh
screencapture -x -R 0,0,200,100 /tmp/t.png && echo OK || echo "まだ無い"
```

権限が入らない場合、GIF はユーザーが自分で録るしかない。ページ側は先に作れる。

## やること

### 1. 数秒の GIF を5本

`ffmpeg` 8.1.2 は導入済み。`avfoundation` が画面デバイスを5つ認識している
（`[4] Capture screen 0` … `[8] Capture screen 4`。物理3台＋仮想3台の一部）。

```sh
# 画面デバイスの確認
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i "Capture screen"

# 録画 → GIF（パレット2パスで色を保つ。1パスだと汚い）
ffmpeg -f avfoundation -capture_cursor 1 -framerate 30 -i "4" -t 6 out.mov
ffmpeg -i out.mov -vf "fps=15,scale=900:-1:flags=lanczos,palettegen" palette.png
ffmpeg -i out.mov -i palette.png -lavfi "fps=15,scale=900:-1:flags=lanczos[x];[x][1:v]paletteuse" out.gif
```

`gifski` は未導入。品質が要るなら `brew install gifski`。

**題材の案（ユーザー指定: ウィンドウを動かす / 仮想ディスプレイ内で複数の PiP が動く / など）**

1. **複数 PiP** — 仮想ディスプレイ3台の PiP を並べて、それぞれ中身が動いている
2. **操作モード** — PiP をクリック（1回目=フォーカス、2回目=操作モード）→ カーソルが
   仮想ディスプレイへ移り、そこのアプリを操作 → 端まで動かして離脱
3. **主モニタに集める** — PiP を見えない場所（仮想ディスプレイ上）へ散らしてから、
   メニューの「すべての PiP を主モニタに集める」で呼び戻す
4. **PiP ごとの設定** — 片方だけ「常に最前面」、もう片方だけ 30fps にする（サブメニュー）
5. **Mission Control** — 常に最前面 OFF なら Control + ↑ に PiP が出る／ON だと出ない

録画の下準備として、シナリオは CGEvent スクリプトで自動化できる（今日ずっとやっていた要領）。
ただし**操作モードの録画中はマウスが仮想ディスプレイに取られる**ので、Esc 5連打の脱出を
スクリプトに必ず仕込む。

### 2. GitHub Pages の宣伝ページ

- リポジトリ: https://github.com/GridJapan/gjPiPWindow （public、main）
- Pages を有効化する（`gh api -X POST repos/GridJapan/gjPiPWindow/pages` か Settings）
- `docs/` を publish 元にするのが楽（main ブランチの `/docs`）
- 中身: 何ができるか、GIF 5本、インストール手順（`make-signing-cert.sh` → `build.sh`）、
  必要な権限（画面収録・アクセシビリティ）、FreeDisplay との併用

**注意: スライドではないので `~/claude/context/gj-context-vault` のスライドデザインガイドは対象外。**
ただしイラストが要るなら、そのガイドの大原則どおり Codex CLI (`codex exec`) で生成する。
CSS で図形を並べて代用しない。

## 再起動テストの基準（2026-07-17 19:50 時点）

再起動後、これと突き合わせる。**解像度が残っているかが本番**（今日実装した機能）。

```
BenQ EX3410R              3440x1440  at (    0,    0)  DefaultDesktop.heic  [主]
Built-in Retina Display   2056x1329  at (-2056,    0)  DefaultDesktop.heic
LINK                      1920x2400  at ( 3440,    0)  DefaultDesktop.heic
FreeDisplay GridJapan     2048x1280  at ( 5360,   20)  nekocats.png
FreeDisplay GridJapan 2   1920x1080  at ( 7408,   20)  cyber-cat.png
FreeDisplay GridJapan 3   1280x720   at ( 9328,   20)  cyber-dog.png
```

| 項目 | 予測 | 根拠 |
|---|---|---|
| 仮想3台が存在 | 残る | autoCreate=true、ログイン項目に登録済み |
| **解像度** | 残る | `65ca37c` で実装。**ここが検証対象** |
| 壁紙 | 残る | 参照先ファイルが実在（`~/claude/live/` と `~/claude/live/wallpapers/`） |
| 配置（位置） | **不明** | 記憶する機能は無い。macOS 任せ |
| PiP ウィンドウ | 消える | gjPiP は開いていた PiP を記憶しない |

`fd.arrangement.externalAbove` は消去済み（初回起動時に true が再度書かれる）。
主ディスプレイが BenQ（外部だが原点を持つ）なので、今日入れたガードにより自動配置は発火しない見込み。

検証コマンド:

```sh
swift -e 'import AppKit
for s in NSScreen.screens {
  guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
  let b = CGDisplayBounds(n)
  print("\(s.localizedName): \(Int(b.width))x\(Int(b.height)) at (\(Int(b.minX)), \(Int(b.minY)))  \(NSWorkspace.shared.desktopImageURL(for: s)?.lastPathComponent ?? "-")")
}'
```

## 今日ここまでの状態（前提）

- **gjPiPWindow** main = `2492d99`〜`743d700`。今日の変更は全部 main に入って push 済み
  （常に最前面トグル / Mission Control 対応 / 2クリック方式 / 辺ごとの脱出設定 /
  カスケード配置 / PiP ごとの設定 / 主モニタに集める）
- **GridJapan/FreeDisplay** main = `65ca37c`。upstream のバグ4件を修正、UI とドキュメントを英語化、
  仮想ディスプレイの解像度を記憶・保持（System Settings 経由の変更が14秒後に巻き戻る件の対策）
- 仮想ディスプレイ3台が稼働中（FreeDisplay GridJapan / 2 / 3）
- Issue #1: フォーカスされていない PiP の音声ミュート（実現可能か未検証）

## 未解決の宿題

**PiP を左端にくっつけると勝手に中央へ戻る。** 原因未特定のまま止まっている。

分かっていること:
- gjPiP のコードに位置を動かす処理は無い（init 時の1回だけ）。動かしているのは macOS
- `EnableTilingByEdgeDrag` は未設定 = **既定で有効**。端ドラッグでタイル配置が働く
- PiP は `contentAspectRatio` でアスペクト比を固定しているので、左半分の形にはなれない

仮説（未検証）: タイル配置が要求する形にできず、macOS が窓を置き直している。
検証には**数十秒 PiP に触らずにいてもらう**必要がある（ユーザーが同時に操作していると
測定が競合して測れない。今日一度それで失敗した）。
