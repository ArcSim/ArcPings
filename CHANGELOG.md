# 1.0.1

### New Features
- **Collapsible sections**: Every section in the options window now has a header bar you can click to fold it away, so you can shut the parts you are not working on and keep the rest on screen. Your choices are remembered.

### Improvements
- **New default entry layout**: Out of the box a ping now reads "Arcstorm [Windfury Weapon] will be ready in 0:12!", with the sender sitting just left of the callout and the callout centred. The old default anchored the sender to the timestamp, which is hidden by default. If you have already positioned your own pieces nothing changes; if you have not, this is the new starting point, and Reset Whole Layout gives you the same thing.

### Bug Fixes
- **Bartender4 keybinds now work**: Ping Keys could not read your keybinds on Bartender4 at all, so spells sitting on those bars simply never pinged. It now reads the binding the way Bartender and LibActionButton actually store it.
- **Your other bars are no longer ignored**: With Bartender4 or ElvUI installed, only those bars were read and the rest of your bars were dropped. Every bar you have is now checked.
- **Keys lost to other bar addons**: Fixed "ping every time I press its key" losing its key when a bar addon refreshed its bindings at the same moment. Arc Pings now always applies its keys last.
- **Wrong spell after rearranging your bars**: Fixed pings using an out-of-date spell or key when a bar addon swapped a button out, which could happen after moving spells around.
- **Typed window position did nothing**: Fixed the feed window snapping straight back when you typed an X or Y position, or switched a setting back to a per-character override.
- **Options window jumped while resizing**: Dragging the bottom-right corner moved the whole window instead of just that corner.

### Improvements
- **Cleaner options panel**: Toggles are now proper checkboxes that sit next to the setting they belong to, lined up in one column, with the description on hover instead of taking up a row. Buttons got a clearer look to match.
- **Window Layout tab reorganised**: Position and Size are now two side-by-side boxes when the window is wide enough and stack when it is not, sliders stretch to fill the space, and the toggles moved into their own Behavior group.
- **Ping Keys tab tidied**: The spell picker, the Add By Spell ID box and Rescan Bars are grouped so it reads as two clear rows instead of one crowded one.

# 1.0.0

### New Features
- **Ping Keys** — Hold a key and press a spell's normal key to ping its cooldown to the group instead of casting it. Let go and the key casts as usual. It reads the keybinds you already have, including ElvUI, Bartender and other bars.
- **Per-spell behaviour** — Every spell you pick can ping while you hold the ping key, ping every time you press its own key, or use a separate key that only pings and never casts.
- **Presses Per Ping** — Stop a spammed button flooding the group. Set it to every 2nd press and the cast still goes through every time; only the callout is spaced out.
- **Auto-Ping** — A master switch for every spell set to ping on every press, with its own key so you can silence and restore them mid-fight. That toggle works in combat.
- **Ping Feed** — A window listing every ping your group sends, so callouts do not scroll away in chat.
- **Layout designer** — Place the timestamp, sender and callout text yourself: anchor, offset, resize and colour each one, or drag them into place on a live canvas.
- **Show In** — Choose where the feed appears. Open world, dungeons, Mythic Plus, raids, battlegrounds, arenas, scenarios and delves each have their own switch.
- **Alerts** — An optional sound when your group pings, using the full LibSharedMedia library, with a throttle so a busy pull does not turn into a drum solo.
- **Account wide with overrides** — Every setting starts shared across your characters. Change one while a character or spec is selected and only that setting breaks out, so you can share a setup and still put the window somewhere else on an alt.
