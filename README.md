# TokenStatsBar

A macOS menu bar app that shows AI token usage and cost from local pi session logs.

The menu bar shows today's token count. Click it to open a dropdown with:

- today's cost, tokens and requests, with a 14 day chart
- the cost for the last 7 days and for this month
- today's top models by cost
- today's tokens split into input, output, cache read and cache write

TokenStatsBar reads `~/.pi/agent/sessions/**/*.jsonl` on your Mac. It needs no account, no API key and no network
access. Only the numeric usage fields, model, provider and timestamp are read. Message content is never decoded,
stored or shown. Files are read incrementally and watched with FSEvents, with a 60 second timer as a fallback.
Records older than 31 days are not kept.

## Requirements

- macOS 13 or later
- Swift 5.9 or later, from Xcode or the Xcode Command Line Tools (`xcode-select --install`)
- [pi](https://github.com/badlogic/pi-mono), with session logs in `~/.pi/agent/sessions`

## Installation

1. Clone the repository and build the app bundle:

       git clone git@github.com:evadnoob/tokenstatsbar.git
       cd tokenstatsbar
       ./bundle.sh

   `bundle.sh` builds a release binary and creates `TokenStatsBar.app`, signed with an ad hoc signature.

2. Move the app to `/Applications` and open it:

       mv TokenStatsBar.app /Applications/
       open /Applications/TokenStatsBar.app

   The app has no Dock icon. Look for the gauge icon and today's token count in the menu bar.

3. Optional: to start the app at login, open System Settings, go to General, then Login Items, and add
   `TokenStatsBar.app` under "Open at Login".

### Upgrade

    cd tokenstatsbar
    git pull
    ./bundle.sh
    osascript -e 'quit app id "com.evadnoob.tokenstatsbar"'
    rm -rf /Applications/TokenStatsBar.app
    mv TokenStatsBar.app /Applications/
    open /Applications/TokenStatsBar.app

### Uninstall

    osascript -e 'quit app id "com.evadnoob.tokenstatsbar"'
    rm -rf /Applications/TokenStatsBar.app

If you added it to Login Items, remove it there too. The app writes no other files.

## Troubleshooting

If the app is running (`pgrep -fl TokenStatsBar`) but the icon is not in the menu bar:

- A menu bar manager such as Ice or Bartender may have put it in its hidden section. Move it to the visible section
  in that app's settings.
- On a Mac with a notch, macOS hides menu bar items that do not fit next to the notch. Quit other menu bar apps to
  make room.
- On recent macOS versions, check System Settings, Menu Bar, and make sure TokenStatsBar is allowed in the menu bar.

If the dropdown says it cannot read session logs, check that `~/.pi/agent/sessions` exists and contains `.jsonl` files.

## Development

    swift build            # debug build
    tools/run-tests.sh     # run the test harnesses in tools/
    ./bundle.sh            # build TokenStatsBar.app

The code is a library target (`Sources/TokenStatsBarKit`) and a thin executable (`Sources/TokenStatsBarMain`).
Test harnesses are executable targets under `tools/` that use `@testable import`, so they build only in the debug
configuration. `tools/run-tests.sh` runs them with HOME set to a scratch directory in `/tmp`.

## Inspiration

The look and feel is partly inspired by [tokenstat](https://tokenstat.ai), a desktop workspace and usage
tracker for AI coding agents ([announcement](https://gyorgy.sh/blog/tokenstat)). This project is
not affiliated with tokenstat. It is a small personal menu bar app that reads pi session logs only.
