---
version: 1
slug: "assets-js-ircpipe-app-jsx"
primary_target: "assets/js/ircpipe_app.jsx"
related_targets: ["assets/js/ircpipe_app.test.jsx"]
---

# IRC Client Surface

## Mode

Operate. Preserve the established dark slate/cyan IRC client and favor familiar, task-focused controls over decorative treatment.

## Discovery model

Curated Discover remains the beginner-first cross-network entry. A connected server also exposes its own channel directory through the plus action beside the server name and the `/list` command. Explain that server directories contain only public channels the server advertises.

## Channel directory behavior

Opening the directory makes the selected server active and requests IRC `LIST`. Show explicit loading, error/retry, empty/search-empty, and populated states. Users can filter by channel name or topic, join a listed channel, or enter a known channel name directly. A successful join keeps existing server connections intact, places the new channel beneath its server, and makes it active.

## Responsive behavior

Desktop retains the server sidebar and content workspace. Mobile collapses navigation into the existing drawer; directory search, direct join, count, topic, visible-user count, and join action stack without horizontal overflow. Use full-width primary row actions on narrow screens.

## Visual language

Use the incumbent compact top bar, dark near-black ground, cool slate separators, cyan accent for current context and primary actions, system typography, small uppercase utility labels, rounded-md controls, and restrained transitions. Keep hierarchy in spacing and dividers rather than nested cards.
