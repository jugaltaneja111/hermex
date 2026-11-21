# 0182. Talk mode

Area: chat

## Talk is a loop over dictation, send and Listen, not a live audio stream

A Hermes host at the pinned commit has no live audio channel for a remote client. Its `voice.*` RPCs use the host's own microphone and speaker, so they are not used here. Talk records on the phone, sends the recording to the host's `POST /api/audio/transcribe`, puts the transcript through the chat's normal send path, then speaks the finished reply with Listen (the host's speech, or the on-device voice). After that it listens again. Because sending uses the normal path, queueing, slash handling and errors behave the same as for a typed message.

Lives in: `HermesMobile/Features/Chat/TalkMode.swift`, `HermesMobile/Features/Chat/ChatView.swift`

## A pause ends the turn, and a long silence ends Talk

`TalkSilenceDetector` reads the recorder's average power every 100 ms. A turn ends after 1.3 s below -40 dB once speech was heard, or after 90 s. Nothing heard for 10 s ends Talk quietly, so a forgotten session does not keep the microphone open.

Lives in: `HermesMobile/Features/Chat/TalkMode.swift`

## Interrupt is a button, not barge-in

The microphone stays closed while a reply plays. With the speaker on, an open microphone would hear the reply and cut it off. Interrupt stops the playback, and Listen's end starts the next turn.

Lives in: `HermesMobile/Features/Chat/TalkMode.swift`

## Reply end comes from the stream, not from the send

`sendDraftMessage` returns before the reply finishes. Talk advances when `activeStreamID` goes back to nil. A send that returns with no stream running, such as a reply that already finished, advances at once. A send that leaves the draft in the composer counts as not sent. Talk ends when the chat leaves the screen or the app leaves the foreground, because recording stops in the background.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`, `HermesMobile/Features/Chat/TalkMode.swift`

## Talk lives in the composer, not the toolbar

Talk takes the send button's place while the composer is empty and nothing runs. A Talk button beside Chat settings in a bot chat's toolbar did not fit next to the bot pill on iOS 26: the system folded the trailing item into a "…" overflow button. Because that item is one custom view holding two buttons, the overflow menu had nothing in it, and Chat settings could no longer be reached.

Lives in: `HermesMobile/Features/Chat/ChatComposerView.swift`
