# Changelog

## Unreleased

- Add optional end-of-recording LLM summaries with Ollama Cloud, OpenRouter, and Local Ollama presets.
- Add a tolerant Korean markdown summary parser and unit tests.
- Ask for a Notion page on every fresh recording so each meeting can use a separate page.
- Add public-repository documentation and a one-command local app installer.
- Replace surprise permission prompts with a Settings preflight, make system-audio capture opt-in, and defer Keychain reads until a feature needs them.
- Remove the unused Speech Recognition privacy prompt for the on-device SpeechAnalyzer backend.

## 0.1.0

- Live Apple SpeechAnalyzer transcription in a menu-bar app.
- Microphone and system-audio capture with `[나]` / `[상대]` speaker labels.
- Live Notion append through OAuth and a record-time page picker.
