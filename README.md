# Hammerspoon IME Control Script

This is a script for **Hammerspoon** that provides robust IME (Input Method Editor) switching for macOS, specifically optimized for users who frequently switch between English and **CJK (Chinese, Japanese, Korean)** input methods.
It is highly effective for Chromium-based browsers and virtual keyboard software like Deskflow.

これは **Hammerspoon** で動作する、macOS用の堅牢なIME切り替えスクリプトです。特に英語と **CJK（中国語・日本語・韓国語）** 入力を頻繁に切り替える環境に最適化されており、Chromium系ブラウザやDeskflow等のバーチャルキーボードでの利用に最適化されています。

## Features / 特徴

- **CJK Optimized Synchronization**: Simultaneously triggers macOS API and physical JIS keycodes (102/104) to ensure the IME state is updated reliably, even for complex CJK input methods.
- **Watchdog & System Recovery**: Periodically monitors the input watcher and automatically restarts/re-applies IME settings upon system wake or screen unlock.
- **Focus Tracking**: Automatically refreshes and synchronizes IME state when switching windows.
- **Customizable**: Easy to configure keybindings, input sources, and timing parameters.
- **Multilingual Support**: Comments in both English and Japanese.

- **CJK最適化された同期**: macOS APIと物理JISキーコード(102/104)を同時に発行し、複雑なCJK入力メソッドであってもIME状態を確実に更新します。
- **ウォッチドッグ & システム復帰**: 定期的に入力監視の状態をチェックし、システムのスリープ復帰や画面ロック解除時に自動で再起動・IMEの再適用を行います。
- **フォーカス追従**: ウィンドウを切り替えた際に、自動的にIME状態をリフレッシュして同期します。
- **カスタマイズ可能**: キーバインド、入力ソースID、各種タイミング設定を簡単に変更できます。
- **日英併記**: コード内のコメントは日英併記されています。

## Installation / インストール

1. **Install Hammerspoon**: Download and install [Hammerspoon](https://www.hammerspoon.org/).
2. **Setup Scripts**: Place both `init.lua` and `ime.lua` in your `~/.hammerspoon/` directory.
3. **Reload Configuration**: Click **"Reload Config"** from the Hammerspoon menu bar icon.

1. **Hammerspoonのインストール**: [Hammerspoon](https://www.hammerspoon.org/)をダウンロードしてインストールします。
2. **スクリプトの配置**: `init.lua` と `ime.lua` の両方を `~/.hammerspoon/` ディレクトリに配置します。
3. **設定のリロード**: Hammerspoonのメニューバーアイコンから **"Reload Config"** を実行します。

## Keybindings / キーバインド

| Action / 動作 | Shortcut / ショートカット |
| :--- | :--- |
| Toggle IME (Eng/Jpn) / IME切り替え | `Shift` + `F12` |
| Show Debug Info / デバッグ情報表示 | `Shift` + `F11` |

## Configuration / 設定方法

You can customize the behavior by passing a configuration table to `ime.start()` in your `init.lua`.

`init.lua` 内で `ime.start()` に設定テーブルを渡すことで、動作をカスタマイズできます。

```lua
local ime = require("ime")

ime.start({
    -- Example: Customizing Input Source IDs
    sources = {
        eng = "com.apple.keylayout.US", -- US Keyboard
        jpn = "com.apple.inputmethod.Kotoeri.Roman" -- macOS Standard Japanese
    },
    -- Example: Customizing Key Bindings
    bindings = {
        toggle = { key = "space", modifiers = {"cmd", "shift"}}, -- Cmd+Shift+Space
    },
    -- Example: Adjusting Alert behavior
    behavior = {
        showAlert = true,
        alertDuration = 0.8
    }
})
```

## Technical Details / 技術的な詳細

This script uses specific JIS keyboard scan codes to bypass application-level caching:
- **JIS Eisu (102)**: Forces English input mode.
- **JIS Kana (104)**: Forces Japanese input mode.
- **F19 (80)**: Used as a dummy key to refresh the macOS event loop during IME toggle.

While the default settings are for Japanese (JIS), the logic can be applied to Chinese or Korean by updating the `sources` in the configuration.

このスクリプトは、アプリ層のキャッシュを回避するために特定のJISキーコードを使用しています：
- **JIS英数 (102)**: 英数入力モードを強制します。
- **JISかな (104)**: 日本語入力モードを強制します。
- **F19 (80)**: IME切り替え時にmacOSのイベントループをリフレッシュするためのダミーキーとして使用します。

デフォルトは日本語向けの設定になっていますが、設定の `sources` を更新することで中国語や韓国語の入力ソースにも対応可能です。

## License / ライセンス

This software is released under the **Unlicense** (Public Domain). You are free to use, modify, and distribute it for any purpose.

このソフトウェアは **Unlicense** (パブリックドメイン) の下で公開されています。目的を問わず、自由に利用、改変、配布することができます。
