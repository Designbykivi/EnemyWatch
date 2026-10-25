# EnemyWatch

A World of Warcraft: Forever addon for PvP realms that adds an extra layer of awareness of your surroundings.

- Lists nearby opposing-faction players (class-coloured, with level and class). Players targeting you are pinned to the top in red.
- Click a row to target that player.
- Alerts you (raid-warning sound, on-screen text and a chat line) when an enemy player targets you.
- Plays a soft ping when a new enemy is spotted.

## Install

Copy the `EnemyWatch` folder into your WoW Forever `Interface/AddOns/` folder. Type `/ew test` in game to preview the window and the alert.

## Detection

Enemies are detected through enemy nameplates, your target, your mouseover and your group members' targets. The Forever/Midnight addon API doesn't give addons the combat log, so turn on enemy nameplates (press `V` or type `/ew nameplates`) for the best coverage.

Blizzard doesn't let addons re-assign clickable target buttons during combat, so the list layout freezes in combat. Enemies first seen in combat appear in the footer and become clickable rows once combat ends.

## Commands

| Command | Effect |
| --- | --- |
| `/ew` | Show/hide the window |
| `/ew lock` | Lock/unlock dragging |
| `/ew reset`, `/ew scale <0.5-2>` | Position and size |
| `/ew expire <sec>` | Drop contacts unseen this long (default 60) |
| `/ew sound`, `/ew screen` | Toggle the targeted-alert sound / on-screen text |
| `/ew newsound`, `/ew newchat` | Toggle the alerts for newly spotted enemies |
| `/ew nameplates` | Turn on enemy nameplates |
| `/ew clear`, `/ew test` | Clear the list / add test contacts |
