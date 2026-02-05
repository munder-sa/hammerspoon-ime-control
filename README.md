# Hammerspoon IME Control Script

This is a script for **Hammerspoon** that provides robust IME (Input Method Editor) switching for macOS.
It is optimized for Chromium-based browsers and virtual keyboard software like Deskflow.

これは **Hammerspoon** で動作する、macOS用の堅牢なIME切り替えスクリプトです。
Chromium系ブラウザやDeskflow等のバーチャルキーボードでの利用に最適化されています。

## Features / 特徴

- **Force Synchronization**: Simultaneously triggers macOS API and physical JIS keycodes (102/104) to ensure the IME state is updated across all applications.
- **Chromium & Deskflow Support**: Solves the common "IME stuck" issue in Chrome, Edge, and during remote operation via Deskflow/Synergy.
- **Focus Tracking**: Automatically refreshes and synchronizes IME state when switching windows.
- **Multilingual Support**: Comments in both English and Japanese.

- **強制同期**: macOS APIと物理JISキーコード(102/104)を同時に発行し、すべてのアプリでIME状態を確実に更新します。
- **Chromium & Deskflow 対応**: ChromeやEdge、またDeskflow等のリモート操作ソフトで発生する「IME切り替えの遅延や失敗」を解決します。
- **フォーカス追従**: ウィンドウを切り替えた際に、自動的にIME状態をリフレッシュして同期します。
- **日英併記**: コード内のコメントは日英併記されています。

## Technical Details / 技術的な詳細

This script uses specific JIS keyboard scan codes to bypass application-level caching:
- **JIS Eisu (102)**: Forces English input mode.
- **JIS Kana (104)**: Forces Japanese input mode.

If you are using a different keyboard layout (e.g., US, ISO) or want to target different input methods, you can modify the `SOURCES` and `KEYCODES` constants in `init.lua` accordingly.

このスクリプトは、アプリ層のキャッシュを回避するために特定のJISキーコードを使用しています：
- **JIS英数 (102)**: 英数入力モードを強制します。
- **JISかな (104)**: 日本語入力モードを強制します。

他のキーボード配列（US配列やISO配列など）を使用している場合や、別の入力ソースを対象にする場合は、`init.lua` 内の `SOURCES` および `KEYCODES` 定数を適宜書き換えてカスタマイズしてください。

## Tip: Coding with AI / AIとの共同開発

This script was refined with the help of AI. We highly recommend using AI coding assistants (like Cline, GitHub Copilot, etc.) to customize or extend this script. AI can help you quickly identify the correct `currentSourceID` for your specific environment or help you map different key combinations.

このスクリプトのリファクタリングと改善は、AIの支援を受けて行われました。このスクリプトを自分の環境に合わせてカスタマイズしたり、機能を拡張したりする際には、AIコーディングアシスタント（ClineやGitHub Copilotなど）の活用を強くお勧めします。あなたの環境に最適な `currentSourceID` の特定や、新しいキーバインドの設定なども、AIと一緒に進めることでよりスムーズに行えます。

## Keybindings / キーバインド

| Action / 動作 | Shortcut / ショートカット |
| :--- | :--- |
| Toggle IME (Eng/Jpn) / IME切り替え | `Cmd` + `Shift` + `F12` |
| Show Debug Info / デバッグ情報表示 | `Shift` + `F11` |

## Installation / インストール

1. Install [Hammerspoon](https://www.hammerspoon.org/).
2. Place `init.lua` in your `~/.hammerspoon/` directory.
3. Reload the Hammerspoon configuration.

1. [Hammerspoon](https://www.hammerspoon.org/)をインストールします。
2. `init.lua` を `~/.hammerspoon/` ディレクトリに配置します。
3. Hammerspoonの設定をリロードします。

## License / ライセンス

This software is released under the **Unlicense** (Public Domain). You are free to use, modify, and distribute it for any purpose.

このソフトウェアは **Unlicense** (パブリックドメイン) の下で公開されています。目的を問わず、自由に利用、改変、配布することができます。
