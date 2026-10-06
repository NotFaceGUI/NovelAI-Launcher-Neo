# NovelAI Launcher Neo

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · English
</p>

This repository is a continuation of [Aaalice233/Aaalice_NAI_Launcher](https://github.com/Aaalice233/Aaalice_NAI_Launcher).

Maintained for **personal use only**.

## Update history

| Date | Version | Change | Preview |
| --- | --- | --- | --- |
| 2026-10-06 | 4.4.0 | Local taggers gained PixAI Tagger v1.0: the reverse-prompt panel offers a one-click download when it is not installed yet (about 1.96 GB, resumable, verified by SHA-256, mirror configurable) and selects it automatically afterwards, with copyright and style tags emitted at the official thresholds; the AI agent's image interrogation gained a "local interrogation" switch (Settings → Integrations → Task routing → Reverse prompt) that keeps the image on the device, runs the on-device model instead of any remote service, merges the resulting prompt into the conversation and shows it in the tool card. Also fixed installed editions being misdetected as portable after the rename, which sent in-app updates down the wrong channel, and hardened the portable update script to fail fast on a damaged package while logging the failing line. |  |
| 2026-09-30 | 4.3.6 | Added camera-angle control above the prompt: a visual camera editor (drag to orbit, scroll to dolly, double-click to reset) writes camera tags whose weight follows how far the camera has turned, and can append a plain-English camera description with eight-way direction, pitch and tilt in degrees, which V4 and newer models read best; multi-character prompts gained interactions, setting who acts and who receives through the source/target/mutual action tags, and the AI agent can read and write them too. |  |
| 2026-09-29 | 4.3.4 | Added "Export layered PSD" (desktop) to the storyboard toolbar's export menu: a page exports as one PSD with the background and every finished panel on its own layers, and panel layers carry a clipping mask, so the artwork can be re-framed by moving or scaling it in Photoshop or Krita while the visible result still matches the composited page PNG. |  |
| 2026-09-29 | 4.3.3 | Added a controllable comic-storyboard editor: lay out panels directly in the center workspace of the generation page, give each panel its own prompt, frame size, characters and seed; fully controllable irregular panels are supported — polygon frames with editable vertices and one-click irregular layouts such as banner-plus-split rows — with per-panel batch generation and composited page export; generation reuses the existing fixed-tag, Vibe and free-tier clamp pipelines, and the AI agent can read and write storyboards too. | <img src="docs/assets/storyboard-demo.jpg" width="480" alt="Storyboard editor demo"><br><img src="docs/assets/storyboard-demo-irregular.jpg" width="480" alt="Irregular panel layout demo"> |
| 2026-09-13 | 4.3.2 | Added an infinite canvas to the center of the generation page: image, seed to-do and Markdown note nodes can be dragged, resized and linked, canvases can be created and switched per project, and new results can land on the canvas automatically; fixed the AI TAG gallery source failing to load. |  |
| 2026-09-12 | 4.3.1 | Added a "Mode" choice (anime / furry) to the model section and a NovelAI image-generation style preset, and made theme switches reveal through a circular mask from the click position; fixed the style picker not opening and the missing thinking level for DeepSeek V4.1 Flash. |  |
| 2026-09-12 | 4.3.0 | Renamed to NovelAI-Launcher-Neo and moved to independent maintenance from upstream: new Android signing certificate and Windows install location, in-app updates pointing at this repository, and Google Drive / OneDrive cloud backup removed. |  |
