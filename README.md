# Road Trip Radio

A personal iPhone DJ for Spotify Premium. Tap **Start drive** to follow your location, or choose **Plan a drive** to preview musical stops along a destination route. The station considers daylight, weather, your chosen energy, and the time left in the current song. Your own pins take priority at natural track boundaries.

## Install on your iPhone from Windows

1. Get **RoadTripRadio.ipa** from the latest successful **Build iPhone app** run under **Actions → Artifacts → RoadTripRadio-iPhone**. Extract the downloaded ZIP once. The device package targets iPhone with iOS 17 or later. [Builds](https://github.com/intheaggregate/road-trip-radio/actions/workflows/iphone.yml)
2. Install AltServer on Windows and AltStore Classic on the iPhone. Trust the PC, enable Wi-Fi sync, and enable Developer Mode on the phone when prompted. Sign the installation with your own Apple account. [AltStore’s Windows guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)
3. Open the IPA from Files with AltStore, or tap **+** in AltStore’s **My Apps**. A free Apple account requires refreshing within seven days through AltServer on your PC. Refresh before a long trip. [AltStore refresh guide](https://faq.altstore.io/altstore-classic/your-altstore)

## Connect Spotify

1. Sign in to the Spotify developer dashboard with your Premium account, create a personal app, and select **Web API**. For the description, use “A personal road-trip soundtrack.” The repository URL works as the website. [Spotify dashboard](https://developer.spotify.com/dashboard)
2. Register the exact redirect URI **roadtripradio://spotify-callback**. Save it, copy the **Client ID**, then open **Settings → Connect Spotify** in the iPhone app. The app uses PKCE and keeps the refresh token in the iPhone Keychain. A client secret is unnecessary. If testing an additional account, add it to the app's user allowlist. [Spotify mobile redirects](https://developer.spotify.com/blog/2025-02-12-increasing-the-security-requirements-for-integrating-with-spotify) · [Development mode](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)
3. Play a song from a favorite playlist in Spotify on the iPhone. Connect the phone to the car as usual. In **Music**, choose Liked Songs or an owned or collaborative playlist. Optional Mellow, Cruising, and Upbeat labels give the DJ more to work with. Your current Spotify playlist supplies music between picks. Download it in Spotify before a drive with patchy coverage. [Spotify offline listening](https://support.spotify.com/article/listen-offline/)

## First drive

Open **Places → Pin a song**, find a landmark or tap the map, and choose a track. On the **Drive** tab, tap **Start drive** and grant location access. For a planned trip, use **Plan a drive** first. A location fix is needed to calculate the route.

The app requests location updates for the duration of the drive, including while locked. It predicts when you will reach a place, selects filler songs by duration, and adds at most one of its own picks to the Spotify queue. Spotify honors the playback queue, so songs you already queued and last-minute detours can affect the timing. Pausing in Spotify pauses the DJ. **End drive** ends GPS tracking and future selections. Spotify can finish music already queued. MusicBrainz coverage varies by region, and the station falls back to your rotation. [Apple background location](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background) · [Spotify's queue](https://developer.spotify.com/documentation/web-api/reference/add-to-queue)

## Optional research with your ChatGPT allowance

The Windows companion runs the official Codex CLI under your own ChatGPT sign-in. It asks for music connected to named places, checks a supporting passage against each source page, and sends compact song suggestions to the phone. Lookup failures and usage limits leave the normal DJ available. The helper requires Python 3.11+ and the Codex CLI. Check your sign-in with **codex login status**. [Codex non-interactive mode](https://developers.openai.com/codex/noninteractive)

**Prepare a trip before departure.** From the project folder on Windows, run the following command and share the resulting JSON file to your iPhone. Open **Places → Import trip file**. The phone stores the suggestions for use along the route.

~~~powershell
python Companion/research.py pack --place "Winslow, Arizona" --place "Flagstaff, Arizona" --output route.roadtrip.json
~~~

**Request occasional live picks.** Start the companion on your Windows PC. It prints a temporary pairing code. In a second terminal, share its loopback endpoint privately with the iPhone. One option is Tailscale Serve, with both devices signed into the same personal tailnet. [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)

~~~powershell
python Companion/research.py serve
~~~

~~~powershell
tailscale serve --bg 8743
~~~

Enter the private HTTPS origin printed by Tailscale and the companion’s pairing code under **Settings → Optional ChatGPT research**. Enable **Live picks during drives**. Keep the PC awake and the companion running for live requests. A code changes when the companion restarts. The iPhone uses only the paired service and sends a town, energy, and weather category. Pre-trip requests send the place names you enter. The companion sends these inputs to Codex, accepts one research job at a time, and limits live requests to once every 20 minutes. The phone resolves results against Spotify after research. Spotify listening data, song pins, credentials, and precise GPS coordinates stay out of these model requests.

## Build and verify

Open **RoadTripRadio.xcodeproj** in Xcode on a Mac, or run the included GitHub Actions workflow on a standard public macOS runner. The workflow tests the scheduling engine and companion, builds and verifies an unsigned arm64 IPA, launches the app on an iPhone simulator, and captures its Drive screen. [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

~~~sh
swift test
python3 -m unittest discover -s Companion -p 'test_*.py' -v
bash scripts/package-ios.sh "$TMPDIR/road-trip-radio"
~~~

For the physical road test, start with a short Spotify queue and a pin near the route. Lock the iPhone while a track is playing. Listen for the pinned song at the next natural transition. Repeat with a detour, a pause in Spotify, and a gap in cell service. After reconnection, the DJ reconciles its pending selection and uses your latest position.

## Credits and privacy

Apple Maps supplies route previews. Open-Meteo supplies the current weather, and MusicBrainz supplies independent artist origins and recording credits. The starter landmarks link to their sources in **Places**. The app stores preferences, personal pins, and imported research on the phone. Routes and the drive queue are held in memory. Route requests use Apple services, weather requests use rounded coordinates, and regional music lookups use approximate areas. Spotify receives the normal authorized library and playback requests. **Disconnect Spotify** clears the local account connection and its pins and playlist choices. [Open-Meteo](https://open-meteo.com/) · [Weather data license](https://creativecommons.org/licenses/by/4.0/) · [MusicBrainz](https://musicbrainz.org/)

DM Serif Text is distributed with its SIL Open Font License. The Spotify mark identifies links to Spotify.
