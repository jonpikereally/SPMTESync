# LTC Bridge error codes

Every error LTC Bridge shows has a code like `LB-202`. Find your code below to
see what happened and what to try.

**Getting help from an AI assistant:** in the error alert, click **Copy Error
Details**, then paste it into your assistant together with a link to this page
(or its plain-text version:
https://raw.githubusercontent.com/jonpikereally/SPMTESync/main/ERRORS.md).
The details include the code, what went wrong, and your LTC Bridge and macOS
versions. Audio is never recorded or included.

Where errors show up:

- **Alerts** show the code, plus **Copy Error Details** and **Open Error List**
  buttons. Hovering over the error text points you here.
- **Background problems** (a device unplugged mid-show, say) appear as an
  orange **⚠️ Problem LB-xxx** banner at the top of the window instead of an
  alert, so nothing pops up over your show. Click it for the full details.
- **The status line** under the timecode shows codes for input problems too.
- **The installer** (Install LTC Bridge.command) prints its code in the
  Terminal window.
- **Every error** is also written to
  `~/Library/Application Support/LTC Bridge/errors.log`.

Codes are permanent: a code always means the same thing and is never reused.
Codes are grouped by area: 1xx updates, 2xx audio input, 3xx MIDI output,
6xx the installer, 999 anything else.

| Code | What happened | What to try |
|---|---|---|
| LB-101 | No update source is set. | Set one with “Update Source…” in the LTC Bridge menu, or leave it empty to use the built-in source. |
| LB-102 | The update source isn't a web link or a file path. | Set one with “Update Source…” in the LTC Bridge menu, or leave it empty to use the built-in source. |
| LB-103 | Couldn't reach the update source. | Check your internet connection and try again. |
| LB-104 | The update server returned an error. | Try again in a few minutes. If it keeps happening, download the latest version from GitHub. |
| LB-105 | The update information is damaged or in the wrong format. | The published update is broken. Download the latest version from GitHub instead. |
| LB-106 | Couldn't download the update. | Try again in a few minutes. If it keeps happening, download the latest version from GitHub. |
| LB-107 | Couldn't unpack the downloaded update. | The published update is broken. Download the latest version from GitHub instead. |
| LB-108 | The downloaded update doesn't contain LTC Bridge. | The published update is broken. Download the latest version from GitHub instead. |
| LB-109 | The downloaded update is a different app. | The published update is broken. Download the latest version from GitHub instead. |
| LB-110 | The downloaded update is damaged. | The published update is broken. Download the latest version from GitHub instead. |
| LB-111 | Couldn't start installing the update. | Make sure LTC Bridge is in ~/Applications and that the folder isn't locked, then try again. |
| LB-112 | Installing the update failed, so the previous version was kept. | Make sure LTC Bridge is in ~/Applications and that the folder isn't locked, then try again. |
| LB-113 | Couldn't move an old backup copy of LTC Bridge out of the Applications folder. | Drag “LTC Bridge Previous.app” from your Applications folder to the Trash. It's only a backup of the previous version. |
| LB-201 | LTC Bridge isn't allowed to use audio inputs, so it can't hear the timecode. | Turn LTC Bridge on in System Settings → Privacy & Security → Microphone, then quit and reopen it. If it's already on, turn it off and on again. |
| LB-202 | The selected audio input isn't connected. | Plug the interface back in or start Dante Virtual Soundcard. LTC Bridge reconnects by itself as soon as the device appears. |
| LB-203 | Couldn't start listening to the audio input. | Check that the device works in Audio MIDI Setup and isn't in use exclusively by another app, then pick it again. |
| LB-204 | The audio input stopped delivering audio, so LTC Bridge restarted it. | Usually a driver hiccup or a sample-rate change. If it keeps happening, check the interface's clock and connection. |
| LB-301 | Couldn't create the “LTC Bridge” MIDI port, so no MTC can be sent. | LTC Bridge retries automatically. If it keeps happening, restart the Mac (the MIDI system may be stuck). |
| LB-302 | The extra MIDI destination isn't connected. Other enabled outputs keep running. | Reconnect the device or network session, or choose “None” under “Also send to”. |
| LB-303 | Sending MTC failed. | Check the destination under “Also send to”, or choose “None”. |
| LB-304 | macOS refused real-time priority for the MTC sender, so MTC timing may wobble by a few milliseconds. | Quit and reopen LTC Bridge. Close heavy apps you don't need during the show. Logic usually still chases fine. |
| LB-305 | Couldn't turn on network MIDI, so MTC isn't going out over the network. | Check that this Mac is on a network, then open Audio MIDI Setup → Window → Show MIDI Network Setup and look at the session there. Turn network output off and on again in LTC Bridge. |
| LB-306 | Couldn't connect to that network address. | Type an IP address or host name, optionally followed by :port — rtpMIDI on Windows uses 5004 by default. Example: 192.168.1.20:5004 |
| LB-307 | This Mac has no network MIDI session yet, so MTC can't go out over the network. | Open Audio MIDI Setup → Window → Show MIDI Network Setup, click + under My Sessions, and tick the new session. LTC Bridge picks it up within a few seconds. |
| LB-601 | The installer couldn't copy LTC Bridge into ~/Applications. | Check that ~/Applications exists and isn't locked, then run the installer again. |
| LB-602 | The installer couldn't sign LTC Bridge for this Mac. | Run the installer again. If it keeps happening, make sure the Xcode Command Line Tools are installed (`xcode-select --install`). |
| LB-603 | LTC Bridge was installed but couldn't be opened. | Open it yourself from ~/Applications (right-click → Open the first time). |
| LB-999 | Something unexpected went wrong. | Try again. If it keeps happening, copy the details and ask for help. |
