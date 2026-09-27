# Wanda — AI voice assistant for macOS

Wanda is a menu bar assistant for the Mac. You talk to it (or type), and it answers out loud. Simple questions and tasks — the time, the weather, what's playing on Spotify, opening and arranging apps — are handled instantly on your Mac without using the AI. Everything else goes to an Azure OpenAI model through a small local Python server, which also generates Wanda's natural-sounding voice with [Kokoro](https://github.com/thewh1teagle/kokoro-onnx).

- **Talk hands-free** — say "Hey Wanda", just "Wanda" (or a nickname) while its window is open, or nod / shake / tilt your head with AirPods.
- **Answers on your Mac, no AI tokens** — time, date, weather, Spotify/Apple Music, open apps, disk space, volume.
- **Does things on your Mac** — opens several apps and fits their windows on screen, and saves documents the AI writes to your Documents folder.
- **Music-friendly** — Spotify and Apple Music are turned down while Wanda speaks, then back up.
- **Natural voices** — Kokoro AI voices run locally on your Mac (default: Nova), with Apple voices as a fallback.
- **Chat history** — saved on your Mac; open, rename or delete past chats from a sidebar.
- **Two looks** — a full chat window, or a compact Siri-style card with an animated logo that glows as Wanda speaks.
- **Takes care of its server** — the app starts the Python server when it launches and stops it when you quit.
- **Demo mode** — plays a scripted conversation that shows it all off, ready for screen recordings.

---

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install)
  - [1. Get the code](#1-get-the-code)
  - [2. Set up the server](#2-set-up-the-server)
  - [3. Build and run the Mac app](#3-build-and-run-the-mac-app)
  - [4. Install Wanda as a regular app (optional)](#4-install-wanda-as-a-regular-app-optional)
- [Using Wanda](#using-wanda)
- [Settings](#settings)
- [Where Wanda keeps things](#where-wanda-keeps-things)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Project structure](#project-structure)
- [Server API](#server-api)

---

## How it works

```mermaid
flowchart LR
    You((You)) -- voice / text --> App["Wanda.app<br/>(SwiftUI, menu bar)"]
    App -- "time, music, apps, windows,<br/>volume, disk, documents" --> Mac[(Your Mac)]
    App -- forecasts --> Weather["Open-Meteo<br/>(free weather API)"]
    App -- "HTTP 127.0.0.1:8000" --> Server["Python server<br/>(FastAPI)"]
    Server -- chat --> Azure["Azure OpenAI<br/>(gpt-4.1)"]
    Server -- history --> Mongo[(MongoDB Atlas)]
    Server -- speech --> Kokoro["Kokoro TTS<br/>(runs locally)"]
```

| Part | Where | What it does |
|---|---|---|
| **Mac app** | [`Interface/Wanda/`](Interface/Wanda) | Menu bar app: chat window, voice input, wake word and head gestures, on-Mac answers and actions, voice output, chat history, demo mode. Starts and stops the server. |
| **Server** | [`server/`](server) | FastAPI app on `127.0.0.1:8000`: AI chat (Azure OpenAI + MongoDB history), Kokoro text-to-speech, opening/closing apps. |
| iOS app | [`Interface/Wanda_Mobile/`](Interface/Wanda_Mobile) | Early placeholder; not functional yet. |

Speech recognition (your voice → text) uses Apple's built-in recognizer. The "Hey Wanda" listener runs **on-device**, so nothing you say is sent anywhere until you've called Wanda. Weather comes from [Open-Meteo](https://open-meteo.com) (free, no account); only coordinates or a city name are sent.

---

## Requirements

| | |
|---|---|
| **Mac** | macOS 13.6 (Ventura) or later. Apple Silicon or Intel. |
| **Xcode** | Xcode 15 or later (tested with Xcode 16.2), and an Apple ID signed in to Xcode for code signing (a free account works). |
| **Python** | Python 3.10 or later (tested with 3.12). From [python.org](https://www.python.org/downloads/macos/) or `brew install python@3.12`. |
| **Azure OpenAI** | An Azure OpenAI resource with a chat model deployed (Wanda uses a deployment named `gpt-4.1`) and its API key. |
| **MongoDB** | A MongoDB Atlas cluster (the free tier is fine) and its connection string. Stores the AI's conversation history. |
| **Microphone** | For voice input. A Mac mini has no built-in mic — use AirPods, a headset or a USB mic. |
| **AirPods (optional)** | For head gestures: AirPods Pro, AirPods (3rd generation or later) or AirPods Max, on macOS 14 or later. |
| **Disk** | About 350 MB for the Kokoro voice model. |

---

## Install

### 1. Get the code

```sh
git clone https://github.com/JonJones98/WANDA-A.I-Assistant.git
cd WANDA-A.I-Assistant
```

Keep the folder where it is after building: the app finds the server by its location in this repository (see [Moving the server](#moving-the-server)).

### 2. Set up the server

Create the Python environment (the app expects it at `server/wandaenv`):

```sh
cd server
python3 -m venv wandaenv
source wandaenv/bin/activate
python -m pip install -r requirements.txt
```

Download the Kokoro voice model, one time (about 340 MB):

```sh
mkdir -p tts_models
curl -L -o tts_models/kokoro-v1.0.onnx https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx
curl -L -o tts_models/voices-v1.0.bin  https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
```

**Keys and connection string.** Create `server/.env` (it's in `.gitignore`, so it's never committed — on a second Mac, copy it over or create it again):

```env
OPENAI_API_KEY=your-azure-openai-key
MongoDB_Connection_String=mongodb+srv://USER:PASSWORD@your-cluster.mongodb.net/?retryWrites=true&w=majority
```

> The variable names are case-sensitive — use `MongoDB_Connection_String` exactly as written.

**Your Azure resource.** The endpoint and deployment are set at the top of [`server/wanda_openai.py`](server/wanda_openai.py). Change them to match your Azure OpenAI resource:

```python
endpoint = "https://YOUR-RESOURCE.openai.azure.com/"
deployment = "gpt-4.1"   # the name of your chat model deployment
```

**MongoDB.** In Atlas, allow your Mac's IP address under *Network Access* (or `0.0.0.0/0` while testing). Wanda creates a `WandaDB` database with `Chat_History`, `Users` and `Commands` collections automatically.

**Check the server** (optional — the app starts it for you), from the `server` folder with `wandaenv` active:

```sh
python -m uvicorn main:app --reload
```

Use `python -m uvicorn`, not plain `uvicorn`: if uvicorn is also installed outside the environment, plain `uvicorn` may run that copy, which fails with `ModuleNotFoundError: No module named 'pymongo'`.

Open <http://127.0.0.1:8000> — you should see `{"message":"Welcome to Wanda Voice AI Assistant!"}`. Interactive API docs are at <http://127.0.0.1:8000/docs>. Stop it with `Ctrl+C`.

### 3. Build and run the Mac app

1. Open `Interface/Wanda/Wanda/Wanda.xcodeproj` in Xcode.
2. Select the **Wanda** target → **Signing & Capabilities**:
   - **Team**: choose your own Apple ID / team.
   - **Bundle Identifier**: if Xcode reports it's unavailable, change `JourneyDev.Wanda` to something unique, e.g. `com.yourname.Wanda`.
3. Choose the **Wanda** scheme and **My Mac**, then press **⌘R**.

Wanda appears as an icon in the **menu bar** (it has no Dock icon). Click it to open the window. The first time, macOS asks for **Microphone** and **Speech Recognition** access — allow both for voice features.

Other features ask for permission the first time you use them:

| Permission | Needed for |
|---|---|
| **Automation → Spotify / Music** | Now playing, music controls, lowering music while Wanda speaks |
| **Accessibility** | Arranging app windows (System Settings → Privacy & Security → Accessibility → Wanda) |
| **Location** | Weather "here" (without it, Wanda uses your time zone's city) |
| **Motion & Fitness** | AirPods head gestures |
| **Documents / Desktop folders** | Saving documents |

Within a few seconds the dot next to "Wanda" in the header turns **green**: the server is running. Try typing `what time is it` (answered on your Mac) and then a general question (answered by the AI).

### 4. Install Wanda as a regular app (optional)

To use Wanda without Xcode running:

1. In Xcode choose **Product → Archive**.
2. In the Organizer: **Distribute App → Custom → Copy App**, and save it.
3. Drag **Wanda.app** into **/Applications** and open it.
4. To start it automatically: **System Settings → General → Login Items → Open at Login → +**, and pick Wanda.

The app remembers where the repository's `server` folder was when it was built, so leave the repository in place (or see [Moving the server](#moving-the-server)).

---

## Using Wanda

### Opening and closing

| Action | How |
|---|---|
| Show / hide the window | Click the Wanda icon in the menu bar |
| Hide the window | **–** in the header, or **✕** in minimal mode |
| Quit Wanda (and stop the server) | ⏻ in the header, or **⌘Q** |
| Move the window | Drag the header or any empty area |
| Resize | Drag an edge, or use the expand button (↖↘) for a large window |

The window floats above other apps and appears on every desktop.

### Talking to Wanda

| Way | How |
|---|---|
| **Wake word** | Say **"Hey Wanda"** (also "Hi / Hello / OK Wanda"), wait for the chime, then ask. |
| **Just the name** | With the window open, simply say **"Wanda"** — or your nickname — to start listening. |
| **Head gestures** *(experimental)* | With AirPods in, **nod twice**, **shake your head** or **tilt your head twice** to start or stop listening. |
| **Mic button** | Click 🎤 in the message bar. Wanda sends your request when you pause. |
| **Typing** | Type and press **Return**. |

A red **Listening…** panel shows your words as you speak. Replies to spoken requests are read aloud; turn on **Read every reply aloud** in the voice panel to hear typed ones too. Saying "Hey Wanda" while Wanda is talking interrupts the reply.

Choose how Wanda wakes up in the voice panel's **Wake up with** menu: "Hey Wanda", a head gesture, or the mic button only. Only one is active at a time. Head gestures use the AirPods' motion sensors, not the mic, so music stays at full quality until you actually talk (see [Troubleshooting](#troubleshooting)).

A chime (Tink) plays when Wanda starts listening, however it started, and a softer Pop when it stops.

When you start talking, Spotify or Apple Music is paused and plays again about a second after Wanda finishes answering; if your request was about the music ("pause", "next song"), it's left as you asked. Music that plays during a reply is turned down to 30% and faded back afterwards; if you change its volume in the meantime, your setting is kept.

### Answers on your Mac (no AI)

These are answered instantly on your Mac, marked **On your Mac**, and work even when the server is down. Say **"list tools"** to see this list in Wanda.

| | Try saying |
|---|---|
| Time and date | "What time is it?" · "What's today's date?" |
| Weather *(via Open-Meteo)* | "What's the weather?" · "Forecast for tomorrow" · "Will it rain this week in Seattle?" · "How cold is it outside?" |
| Music (Spotify or Apple Music) | "What's playing?" · "Pause" · "Play" · "Next song" · "Previous song" |
| Open and close apps | "Open Safari" · "Close Spotify" *(uses the server, not the AI)* |
| Open and arrange apps | "Open Safari, Notes and Spotify" · "Arrange my windows" · "Put my windows side by side" |
| Apps in use | "What app am I using?" · "What apps are open?" |
| Disk space | "How much disk space do I have left?" |
| Volume | "What's the volume?" · "Set volume to 40" · "Turn it up" · "Mute" |
| Window view | "Switch to mini view" · "Full view" |
| Save an answer | "Save that to Documents" |
| Demo | "Start demo" |

Wanda only answers locally when the whole question matches — "What time is it **in Tokyo**?" goes to the AI instead of getting the wrong local answer. Questions sent to the AI include a short note about your Mac (time, song playing, app in use), so follow-ups like "tell me about this artist" work. Music control never launches a player that isn't already open.

Arranged windows go on the screen Wanda is on: 2 apps side by side, 3 as one large window with two stacked beside it, 4 or more in a grid. Everyday app names work ("chrome", "VS Code", "settings", "the Notes app"); if a name isn't an app ("open Spotify and play jazz"), the request goes to the AI instead.

### Documents

Ask Wanda to write something and save it, and the AI writes it, Wanda saves it as a text file in **Documents** and opens it in TextEdit:

- "Create a 3-day itinerary for Tokyo and save it to Documents"
- "Write a packing list for a beach trip and save it"
- "Make a document summarizing our conversation"

The file is named after the document's title and never replaces an existing file. **"Save that to Documents"** saves Wanda's last answer as it is, without calling the AI. Requests that don't mention saving or a document ("write a poem about rain") are answered in the chat as usual.

### Chat history

Click the **sidebar** button (far left of the header) to show your chats, grouped by date.

- **Open** a chat: click it. Wanda reopens your last chat at launch.
- **Rename**: double-click the title, or use **…** / right-click → **Rename**.
- **Delete**: **…** / right-click → **Delete…** (asks first).
- **New chat**: the ✎ button.

### Minimal mode

Click the **minimal view** button in the header (or say "switch to mini view") for a compact, see-through card: your last request, Wanda's reply, and the Wanda logo, which glows and pulses on every word Wanda speaks. Hover for the mic and **full view** buttons. "Hey Wanda" opens straight into this card.

### Demo mode

Click **▶** in the header or say **"start demo"** to play a scripted conversation using Wanda's real voice, listening panel and animations. It switches to the mini view, opens Maps and Spotify and arranges them, plays music, answers the time and weather for real, plans a trip to Lisbon (Safari search, Maps pin, windows laid out, itinerary in TextEdit), tidies up the apps, saves the itinerary to your **Desktop**, then answers a storage question with your real disk numbers.

- AI-style answers in the demo are pre-written, so it uses no tokens and works without the server.
- Demo messages aren't saved to your chat history; when it ends, your previous chat and view come back and music it started is paused.
- **Esc** or **Stop demo** ends it early; so do "Hey Wanda", typing, or opening another chat.
- **Recording tip:** hide the demo bar with its 👁 button (or turn off **Show the demo status bar**), and start with Safari, Maps, TextEdit and Spotify closed — the demo quits them as part of the script.
- Edit the script in [`Demo.swift`](Interface/Wanda/Wanda/Wanda/Demo.swift).

---

## Settings

Open the **voice panel** with the speaker button in the header.

| Setting | What it does |
|---|---|
| **Read every reply aloud** | Speak typed replies too (spoken requests are always answered aloud). |
| **Show the demo status bar** | Turn off to record the demo without its bar. |
| **Pause music while I talk to Wanda** | Pause Spotify and Apple Music while you talk, and play them again after the answer (on by default). |
| **Lower music while Wanda speaks** | Turn Spotify and Apple Music down during replies (on by default). |
| **Wake up with** | Saying "Hey Wanda", nodding twice, shaking your head, tilting your head twice, any head gesture, or the mic button only. |
| **Just say the name when the window is open** | ("Hey Wanda" mode) With the window visible, "Wanda" or a nickname alone starts listening. |
| **Nickname** | ("Hey Wanda" mode) Extra names Wanda answers to, e.g. `Jarvis` (separate several with commas). |
| **Voice** | Kokoro AI voices (★ = best; default **Nova**) or any installed Apple voice. |
| **Speed / Pitch** | Speaking rate and pitch (pitch applies to Apple voices only). |
| **Preview** | Hear the current voice. |

All settings, the window size and the view mode are remembered between launches.

---

## Where Wanda keeps things

| What | Where |
|---|---|
| Saved chats | `~/Library/Application Support/Wanda/conversations.json` |
| Server log | `~/Library/Logs/Wanda/server.log` |
| App settings | macOS preferences for `JourneyDev.Wanda` (or your bundle ID) |
| API keys | `server/.env` (never committed) |
| Voice model | `server/tts_models/` (never committed) |
| AI conversation history | MongoDB `WandaDB.Chat_History` |
| Documents Wanda writes | `~/Documents` (the demo's itinerary goes to `~/Desktop`) |

### Moving the server

The app looks for the server in this repository's `server` folder, using the path from when it was built. If you move the server, point Wanda at the new location and relaunch:

```sh
defaults write JourneyDev.Wanda WandaServerDirectory /path/to/server
```

The folder must contain `main.py` and the `wandaenv` environment.

---

## Troubleshooting

**Red dot next to "Wanda" / "I couldn't start my server."**
Hover over the dot for the reason, and check `~/Library/Logs/Wanda/server.log`. Common causes:
- `An Invalid URI host error was received` or `DNS query name does not exist` — the MongoDB connection string is wrong or the cluster was deleted. Copy a fresh one from Atlas (**Connect → Drivers**) into `server/.env`.
- `The server's Python environment is missing` — create `server/wandaenv` and install the requirements (step 2).
- Azure errors (401/404) — check `OPENAI_API_KEY` and the endpoint/deployment in `wanda_openai.py`.
Click the red dot to try again.

**Orange crossed-out mic in the header.**
No microphone is connected. Connect AirPods or a mic — Wanda picks it up automatically within a couple of seconds.

**Music sounds muffled with AirPods.**
While any app uses the AirPods mic, macOS switches them to low-quality call mode. The "Hey Wanda" listener keeps the mic on, so music quality drops. Set **Wake up with** to a head gesture (the mic then only turns on while you talk), use your Mac's built-in mic as the input (System Settings → Sound → Input), or use a wired mic. After you stop talking, Wanda releases the mic completely and the AirPods switch back within a couple of seconds.

**Head gestures don't work.**
The text under **Wake up with** says why: *Waiting for AirPods* means your AirPods don't support head tracking (or aren't in); *can't read head movement* means Motion access is off (System Settings → Privacy & Security → Motion & Fitness). If gestures trigger by accident, choose only one gesture.

**Wanda opens apps but doesn't arrange them.**
Allow Wanda in **System Settings → Privacy & Security → Accessibility**, then say "arrange my windows". If you rebuild with a different signing identity, remove and re-add Wanda there.

**Weather is for the wrong place.**
Allow Location for Wanda in **System Settings → Privacy & Security → Location Services**, or name the place: "weather in Chicago".

**No Kokoro voices in the voice panel.**
The server isn't running or the model files are missing from `server/tts_models/`. Wanda falls back to Apple voices.

**"macOS isn't returning its voice list."**
macOS's voice-download service (`mobileassetd`) isn't responding; Wanda keeps using the current voice. Updating macOS usually fixes it. Kokoro voices aren't affected.

**"I need permission to see Spotify."**
Allow it in **System Settings → Privacy & Security → Automation → Wanda → Spotify / Music**.

**Voice input does nothing.**
Allow Wanda in **System Settings → Privacy & Security → Microphone** and **Speech Recognition**.

**`CLIENT ERROR: TUINSRemoteViewController…` in the Xcode console.**
Harmless macOS log noise from the text-input system; ignore it (filter the console with `-TUINSRemoteViewController`).

**`ModuleNotFoundError: No module named 'pymongo'` (or `fastapi`, `kokoro_onnx`) when starting the server by hand.**
A copy of uvicorn outside `wandaenv` ran instead of the environment's. Start it with `python -m uvicorn main:app --reload` after `source wandaenv/bin/activate` (check `which python` points into `server/wandaenv`). The app itself always uses the environment's Python.

**`zsh: unknown file attribute` when pasting commands.**
zsh doesn't treat pasted `# …` lines as comments. It's harmless; the other commands still run.

**Something else running on port 8000.**
Wanda's server always uses `127.0.0.1:8000`. Stop the other program, or change the port in both `WandaAPIClient.defaultBaseURL` and how you start the server.

---

## Development

**Run the server by hand** (Wanda uses it instead of starting its own):

```sh
cd server && source wandaenv/bin/activate
python -m uvicorn main:app --reload
```

When you quit Wanda it stops the server, including one you started yourself — only `uvicorn` processes on port 8000 running from this `server` folder are touched.

**Run the app's unit tests** (99 tests):

```sh
cd Interface/Wanda/Wanda
xcodebuild test -project Wanda.xcodeproj -scheme Wanda -destination 'platform=macOS' -only-testing:WandaTests
```

Or press **⌘U** in Xcode. Some tests start throwaway uvicorn servers on ports 8767–8773 using `server/wandaenv`, and skip themselves if it doesn't exist.

If Wanda is running from Xcode at the same time, command-line tests can fail with `CodeSign failed` because both builds share a folder. Add `-derivedDataPath /tmp/wanda-tests` to the command to build the tests separately.

**Code signing.** The app is not sandboxed (it needs to start the Python server and control other apps) and uses the hardened runtime with microphone, Apple Events and location entitlements.

**Security.** The server listens only on `127.0.0.1` and has **no authentication** — it can open and close apps on your Mac. Don't expose it on your network or the internet.

---

## Project structure

```
WANDA-A.I-Assistant/
├── Interface/
│   ├── Wanda/Wanda/                  macOS app (Xcode project)
│   │   ├── Wanda/
│   │   │   ├── WandaApp.swift        entry point
│   │   │   ├── WandaPanel.swift      floating window, menu bar icon, app lifecycle
│   │   │   ├── Assistant.swift       wires wake word → dictation → chat
│   │   │   ├── ContentView.swift     full chat view, header
│   │   │   ├── MinimalView.swift     Siri-style card
│   │   │   ├── ChatHistorySidebar.swift, ChatStore.swift   saved chats
│   │   │   ├── ChatViewModel.swift   sending, replies, chat state
│   │   │   ├── LocalIntent.swift, LocalAssistant.swift     on-Mac answers
│   │   │   ├── Weather.swift         Open-Meteo forecasts
│   │   │   ├── WindowArranger.swift  open apps, arrange windows (Accessibility)
│   │   │   ├── Documents.swift       write and save documents
│   │   │   ├── Demo.swift            demo script
│   │   │   ├── CommandParser.swift   open / close app commands
│   │   │   ├── WakeWordListener.swift, SpeechRecognizer.swift, Microphone.swift
│   │   │   ├── HeadGestures.swift    AirPods nod / shake / tilt
│   │   │   ├── MusicDucker.swift     lowers music while Wanda speaks
│   │   │   ├── WandaVoice.swift, VoiceSettings*.swift, WandaOrb.swift
│   │   │   ├── ReplyFormatting.swift Markdown/LaTeX for display and speech
│   │   │   ├── ServerManager.swift   starts/stops the Python server
│   │   │   └── WandaAPIClient.swift  HTTP client for the server
│   │   └── WandaTests/               unit tests
│   └── Wanda_Mobile/                 iOS app (placeholder)
└── server/
    ├── main.py                       FastAPI routes
    ├── wanda_openai.py               Azure OpenAI chat
    ├── wanda_tts.py                  Kokoro text-to-speech
    ├── models/Wanda_DB_Mongo.py      MongoDB models
    ├── requirements.txt
    ├── .env                          your keys (not committed)
    └── tts_models/                   Kokoro model (not committed)
```

---

## Server API

Base URL `http://127.0.0.1:8000` · full interactive docs at `/docs`.

| Method & path | Purpose |
|---|---|
| `GET /` | Health check |
| `POST /genAI/chat` | Ask the AI. Body: `{"user_input": "...", "chat_id": "", "context": ""}` → `{"chat_id": "...", "response": "..."}` |
| `GET /tts/voices` | Kokoro voices |
| `POST /tts/speak` | Speech audio (WAV). Body: `{"text": "...", "voice": "af_nova", "speed": 1.0}` |
| `GET /open?app=Safari` · `GET /close?app=Spotify` | Open or quit an app |
| `GET /custom_command/{name}` | Run a saved custom command |
| `/db/chat_history…`, `/db/user…`, `/db/commands…` | MongoDB records (history, users, custom commands) |

See [`server/README.md`](server/README.md) for server-only details.
