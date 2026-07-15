# WhisperNotion

WhisperNotion is a macOS menu-bar app for live, local transcription of meetings. It shows a floating transcript window, labels microphone and system audio as `[나]` and `[상대]`, and appends confirmed lines to a Notion page while you record.

At the end of a recording, it can optionally send the transcript to an OpenAI-compatible LLM and append a Korean meeting summary to the same Notion page.

## Requirements

- macOS 26.0 or later
- Apple Silicon or Intel Mac supported by the installed Swift toolchain
- Xcode 26 command-line tools (`swift`, `codesign`)
- A Notion OAuth integration created by you

The v1 speech backend uses Apple's on-device SpeechAnalyzer. Speech data stays on the Mac for transcription. The optional summary feature sends the transcript to the provider selected in Settings; choose Local Ollama for an offline summary.

## Install from source

```sh
git clone https://github.com/goosull/WhisperNotion.git
cd WhisperNotion
./scripts/install-app.sh
open "$HOME/Applications/WhisperNotion.app"
```

The installer builds a release `.app`, ad-hoc signs it, and installs it in `~/Applications`. To install in the system Applications folder instead:

```sh
./scripts/install-app.sh release /Applications/WhisperNotion.app
```

This is currently an unsigned/notarized-free developer build. On first launch, macOS may require Control-click → Open. A Developer ID-signed and notarized release is planned before broad distribution.

## First-time setup

1. Open WhisperNotion Settings from the menu-bar item.
2. Create a Notion OAuth integration at <https://www.notion.so/my-integrations>.
3. Register this redirect URI exactly:

   `http://localhost:8127/callback`

4. Paste the integration's client ID and client secret into Settings, then click **Notion 연결**.
5. Grant the integration access to the pages you want to use.
6. Open the **녹음 권한** section in Settings and allow only the inputs you want. Microphone is required for recording; system-audio capture is optional and off by default.
7. Start recording and choose a page.

The app stores the Notion token, OAuth client secret, and optional LLM key in the macOS Keychain. Keychain values are not read when the app launches. No credentials are included in this repository.

## Optional LLM summaries

Enable **녹음 종료 시 LLM 요약** in Settings and select one of these OpenAI-compatible providers:

- Ollama Cloud
- OpenRouter
- Local Ollama at `http://localhost:11434/v1`

For cloud providers, enter your own API key. For Local Ollama, install and run Ollama separately and pull the configured model.

## Development

```sh
swift test
swift build --target WhisperNotionApp
./scripts/make-app.sh release
```

The generated app is written to `build/WhisperNotion.app`.

## Current limitations

- macOS 26 is required for the live Apple SpeechAnalyzer backend.
- The public build is ad-hoc signed and not notarized yet.
- Each user currently creates and enters their own Notion OAuth client credentials.
- Very long summaries use the most recent transcript window rather than map-reduce chunking.

## License

MIT. See [LICENSE](LICENSE).
