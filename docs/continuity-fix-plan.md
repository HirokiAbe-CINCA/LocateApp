# 位置情報の継続性 修正計画(Continuity Fix Plan)

作成日: 2026-07-07

> **⚠️ このファイルの扱いについて**
> このファイルは修正作業のための一時的な計画書です。
> **以下のすべての項目が完了したら、このファイル(`docs/continuity-fix-plan.md`)自体を削除してください。**
> 最終チェック項目としても末尾に記載しています。恒久的に残す知見は README や
> `docs/improvement-backlog.md` に移してから削除すること。

## 背景

開発者テストとして「継続的・途切れない位置情報シミュレーション」を行いたいが、
現状のアプリでは位置情報が勝手に途切れる(または途切れた後に無人で復帰できない)ケースがある。
コードレビュー(2026-07-06)の結果、原因は「途切れない仕組み」ではなく
「**途切れた後に無人で戻れない仕組み**」に集中していることが判明した。
鍵は管理者認証の排除(A-1)。

現状のアーキテクチャ:

- トンネル: `pymobiledevice3 lockdown start-tunnel` を osascript の管理者権限で起動し、PIDファイルで管理
- 位置設定: `simulate-location set` を nohup でデタッチ起動。このプロセスが生きている間だけ位置が維持される
- 監視: `AppModel.startLocationContinuityMonitoring()` の10秒ポーリングで両プロセスの生存を `ps` で確認し、
  死んでいたら自動復旧(最大3回・10秒間隔)

---

## A. 途切れの直接原因への修正(コード)

### A-1. 【最優先】復旧のたびに管理者認証ダイアログが必要な構造を排除

- [ ] 対応完了

**対象**: `Sources/LocateAppCore/LocateProcess.swift` (`adminTunnelScript`)、`Sources/LocateApp/AppModel.swift` (`ensureTunnel`)

**問題**: トンネル再構築は毎回 osascript の管理者プロンプトを要求する。連続テスト中にトンネルが落ちると、
自動復旧が突然パスワードダイアログを出し、ユーザー不在なら osascript が120秒タイムアウト→3回失敗→
「不確実」マークで監視自体が停止する(`checkActiveLocationContinuity` の `!activeLocationMayRemain` ガードにより、
一度不確実になると自動復旧は二度と動かない)。「勝手に途切れて戻らない」の最有力シナリオ。

**修正内容**: SMAppService による特権ヘルパー(または launchd 常駐の tunneld)に移行し、
管理者認証を初回インストール時の1回だけにする。復旧パスから osascript を完全に排除する。
`docs/improvement-backlog.md` の Deferred Decisions に既載の項目を最優先に昇格。

**完了条件**: トンネル再構築が管理者ダイアログなしで成功し、無人状態での自動復旧が通ること。

### A-2. 復旧リトライの打ち切り(3回×10秒)をやめ、デバイス再接続で自動復帰

- [ ] 対応完了

**対象**: `Sources/LocateAppCore/LocationContinuity.swift` (`LocationAutoRecoveryPolicy`)、`Sources/LocateApp/AppModel.swift`

**問題**: 復旧は約30秒で打ち切り。USBの一時的な抜き差しやiPhoneの再認識に30秒以上かかると諦め、
その後デバイスが戻っても再移動しない。

**修正内容**:
- 「接続が戻り次第、自動で再移動する」モード(開発者向けトグル)を追加し、リトライを指数バックオフで継続
- `usbmux list` のポーリングまたは IOKit のUSB接続通知でデバイス再接続を検知し、復旧を再トリガー

**完了条件**: USBを60秒抜いて再接続した際、手動操作なしで移動先が復元されること。

### A-3. プロセス生存=位置が有効、という判定にヘルスチェックを追加

- [ ] 対応完了

**対象**: `Sources/LocateApp/AppModel.swift` (`checkActiveLocationContinuity`)、`Sources/LocateAppCore/LocateProcess.swift`

**問題**: `ps` でPIDの生存だけを見ているため、トンネル/setプロセスが生きたままDVT接続だけ死んでいる
ゾンビ状態では「有効」と表示し続けるが、iPhone側は実位置に戻っている。

**修正内容**: 数回に1回はトンネル経由の実通信(例: `mounter query-developer-mode-status`)で疎通確認する。
`set.err` の新規出力の監視も併用する。

**完了条件**: トンネルだけを人為的に切断した状態で、ゾンビ状態が1分以内に検知され復旧が始まること。

### A-4. プロセス死亡の検知を10秒ポーリングから即時通知に

- [ ] 対応完了

**対象**: `Sources/LocateApp/AppModel.swift` (`startLocationContinuityMonitoring`)

**問題**: 検知が最大10秒遅れる。

**修正内容**: `DispatchSource.makeProcessSource`(kqueue の EVFILT_PROC)でPIDを監視し即時検知する。
ポーリングはフォールバックとして残す。

**完了条件**: setプロセスを kill した際、1秒以内に復旧が開始されること。

### A-5. App Nap による監視タスクのスロットリングを防止

- [ ] 対応完了

**対象**: `Sources/LocateAppCore/SleepPrevention.swift`、`Sources/LocateApp/AppModel.swift`

**問題**: 取得しているのは IOPM のシステムスリープ抑止のみ。アプリがバックグラウンド/最小化されると
App Nap で `Task.sleep` ベースの監視ループが遅延し、検知・復旧が遅れる可能性がある。

**修正内容**: 移動中は `ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], ...)`
を併用する(既存のスリープ抑止をこれに統合してもよい)。

**完了条件**: アプリを最小化した状態でも監視間隔が維持されること。

### A-6. 無関係なエラーでトンネル状態を破棄しない

- [ ] 対応完了

**対象**: `Sources/LocateApp/AppModel.swift` (`moveToSelectedLocation` / `reapplyActiveLocation` の catch 節)

**問題**: 座標のパースエラー等トンネルと無関係な失敗でも `rsdEndpoint = nil` にするため、
次の移動で健全なトンネルがあるのに再構築+管理者認証が発生する。

**修正内容**: トンネル起因のエラー時だけ `rsdEndpoint` / `rsdDeviceID` をリセットする。

**完了条件**: 移動成功後に不正な座標で移動を試み、その後正しい座標で移動しても管理者プロンプトが出ないこと。

### A-7. スリープ復帰後の自動再移動(オプション)

- [ ] 対応完了

**対象**: `Sources/LocateApp/AppModel.swift` (didWake ハンドラ)

**問題**: スリープ復帰時は「不確実」にマークして手動の「前回の場所へ再移動」を促すだけ。

**修正内容**: 復帰時に自動で再移動を試みるオプションを追加する(A-1の特権ヘルパーが前提。無人で完結させる)。

**完了条件**: オプション有効時、スリープ→復帰後に手動操作なしで移動先が復元されること。

### A-8. トンネル準備待ちの15秒固定タイムアウトを緩和

- [ ] 対応完了

**対象**: `Sources/LocateApp/AppModel.swift` (`ensureTunnel` のリトライループ)

**問題**: バンドル版ヘルパーは起動が遅く(READMEにも注記あり)、初回やマシン負荷時に15秒で不足して
「準備できませんでした」→途切れ扱いになる可能性がある。

**修正内容**: タイムアウトを延長し、定数を `LocateAppCore` 側のポリシー型に切り出して設定可能にする。

**完了条件**: バンドル版ヘルパーの初回起動でもトンネル準備が成功すること。

---

## B. UI/UX の改善(連続稼働の開発者テスト観点)

### B-1. 監視状態・継続時間の可視化

- [ ] 対応完了

**対象**: `Sources/LocateApp/DevicePanel.swift`(「現在の移動先」欄)

**修正内容**: 「移動中 00:32:10|監視中(最終確認 3秒前)」のような継続稼働インジケータを追加する。
移動継続時間・最終確認時刻・監視の稼働有無を表示する。

### B-2. 途切れ/復旧時の macOS 通知

- [ ] 対応完了

**対象**: `Sources/LocateApp/AppModel.swift`

**修正内容**: 継続性が失われた時・復旧した時に `UNUserNotificationCenter` で通知+サウンドを出す。
ユーザーはテスト中iPhoneを見ており、Mac画面のステータス1行では気づけないため。

### B-3. 時刻付きイベントログ

- [ ] 対応完了

**対象**: `Sources/LocateApp/AppModel.swift`(status の履歴化)、`Sources/LocateApp/DevicePanel.swift`

**修正内容**: 単一行ステータスは上書きで揮発するため、「いつ・何が起きて途切れたか」を追える
時刻付きイベントログ(直近N件)を診断情報に含めるか折りたたみ表示する。

### B-4. 管理者ダイアログの文脈提示(A-1完了までの暫定)

- [ ] 対応完了

**対象**: `Sources/LocateApp/AppModel.swift` (`runAutoRecovery`)

**修正内容**: 自動復旧が前触れなくパスワード入力を出すと誤キャンセル→復旧完全停止の事故導線になる。
復旧前に `NSApp.activate` でアプリを前面化し「再接続には認証が必要です」と文脈を示す。
A-1が完了すればこの項目は不要になるので、その場合はチェックして飛ばしてよい。

### B-5. リトライポリシーの設定UI

- [ ] 対応完了

**対象**: `Sources/LocateApp/DevicePanel.swift`、`Sources/LocateAppCore/LocationContinuity.swift`

**修正内容**: 「3回/10秒間隔」のコード内定数をUIに出し、「復旧を諦めない」トグルと間隔設定を追加する(A-2と連動)。

### B-6. デバイス再接続時の再移動導線の強化

- [ ] 対応完了

**対象**: `Sources/LocateApp/DevicePanel.swift`、`Sources/LocateApp/AppModel.swift`

**修正内容**: デバイス再接続検知時に「前回の場所へ再移動」ボタンをハイライトし通知する。
A-2の自動実行オプションが有効な場合は自動で実行する。

---

## 対応の優先順位

| 優先度 | 項目 | 効果 |
|---|---|---|
| 1 | A-1 特権ヘルパー化(認証を初回のみに) | 無人復旧が可能になり「途切れたまま」が激減 |
| 2 | A-2 リトライ継続+デバイス再接続検知 | 一時的な切断から自律復帰 |
| 3 | B-1/B-2 稼働インジケータ+途切れ通知 | 途切れに即気づける |
| 4 | A-3/A-4 ヘルスチェック+即時プロセス監視 | ゾンビ状態の誤検知防止・検知の高速化 |
| 5 | A-5/A-6/A-7/A-8、B-3〜B-6 | 復旧品質・体験の底上げ |

## 検証(各修正の完了時に実施)

```bash
bash scripts/run_swift_core_checks.sh
.venv/bin/python -m pytest
./scripts/build_app_bundle.sh
./scripts/e2e_smoke.sh
```

---

## 最終チェック

- [ ] 上記 A-1〜A-8、B-1〜B-6 がすべて完了している(不要と判断した項目は理由をコミットメッセージに残す)
- [ ] 恒久的に残す知見を README / `docs/improvement-backlog.md` に反映した
- [ ] **このファイル `docs/continuity-fix-plan.md` を削除した**
