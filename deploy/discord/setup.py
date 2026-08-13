#!/usr/bin/env python3
# The Discord server's shape, as a script.
#
# Decision 39 puts the community on a Discord we own, and this file is what
# owning it means in practice: channels, roles, safety settings, automod and
# the standing invite are declared here and applied by running it. Repairing
# a drifted server, or rebuilding one after a disaster, is a rerun.
#
# Reads DISCORD_BOT_TOKEN from the environment and nothing else; the bot must
# hold Administrator in exactly one server, or DISCORD_GUILD_ID names which.
# Safe to rerun: what exists by name is kept, what is missing is created, and
# guild settings are asserted every time. It never deletes anything, so a
# channel this file stops naming has to be removed by hand, on purpose.

import base64
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request

API = "https://discord.com/api/v10"

# The mark, rendered for a round tile by icon.py beside this file.
ICON = pathlib.Path(__file__).resolve().parent / "icon.png"

VIEW = 1 << 10
SEND = 1 << 11
ADMINISTRATOR = 1 << 3

# Amber, the HUD's own color.
ADMIN_COLOR = 0xFFB000

RULES_TEXT = """\
Welcome to vectorwake. The game carries no chat on purpose, so this is where \
talk happens.

1. Discord's rules and terms apply everywhere here.
2. Fly under your own name. No impersonating other pilots, or the staff.
3. No spam, no advertising, no invite drops.
4. Trouble? Report the message (right-click, Report Message) or ping @admin.

That's all of it."""

# Channels, in display order. "reuse" names a channel created by Discord's
# server template that we take over rather than duplicate; history survives a
# rename where it would not survive a replacement.
CHANNELS = [
    {"name": "rules", "topic": "The short version of how to behave here.",
     "readonly": True},
    {"name": "announcements",
     "topic": "Releases and fleet news. The game speaks here; nobody else does.",
     "readonly": True, "news": True},
    {"name": "hangar", "topic": "The one room. Anything vectorwake.",
     "reuse": "general"},
    {"name": "staff", "topic": "Admins only: reports, moderation, keys.",
     "private": True},
]


def api(method, path, payload=None):
    body = None if payload is None else json.dumps(payload).encode()
    for attempt in range(5):
        req = urllib.request.Request(API + path, data=body, method=method)
        req.add_header("Authorization", "Bot " + TOKEN)
        req.add_header("Content-Type", "application/json")
        req.add_header("X-Audit-Log-Reason", "deploy/discord/setup.py")
        # Cloudflare bans urllib's default agent outright (their error 1010),
        # and Discord asks bots to identify like this in any case.
        req.add_header("User-Agent", "DiscordBot (https://vectorwake.net, 1.0)")
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                text = r.read().decode() or "null"
                return json.loads(text)
        except urllib.error.HTTPError as e:
            detail = e.read().decode()
            if e.code == 429:
                wait = json.loads(detail).get("retry_after", 2 ** attempt)
                time.sleep(float(wait) + 0.1)
                continue
            sys.exit(f"{method} {path} -> {e.code}\n{detail}")
    sys.exit(f"{method} {path}: rate limited five times, giving up")


def pick_guild():
    guilds = api("GET", "/users/@me/guilds")
    want = os.environ.get("DISCORD_GUILD_ID")
    if want:
        guilds = [g for g in guilds if g["id"] == want]
    if not guilds:
        sys.exit("The bot is in no server (or not the one DISCORD_GUILD_ID "
                 "names). Invite it first, with Administrator.")
    if len(guilds) > 1:
        listing = ", ".join(f"{g['name']}={g['id']}" for g in guilds)
        sys.exit(f"The bot is in several servers ({listing}); "
                 "set DISCORD_GUILD_ID to the one this file owns.")
    g = guilds[0]
    if not int(g["permissions"]) & ADMINISTRATOR:
        sys.exit(f"The bot is in {g['name']} without Administrator; "
                 "reinvite it with that permission or grant it a role.")
    return g["id"], g["name"]


def ensure_role(guild, name):
    for r in api("GET", f"/guilds/{guild}/roles"):
        if r["name"] == name:
            return r["id"], "kept"
    r = api("POST", f"/guilds/{guild}/roles", {
        "name": name, "permissions": str(ADMINISTRATOR),
        "color": ADMIN_COLOR, "hoist": True, "mentionable": True,
    })
    return r["id"], "created"


def overwrites(spec, guild, admin_role, bot_user):
    if spec.get("readonly"):
        return [{"id": guild, "type": 0, "allow": "0", "deny": str(SEND)}]
    if spec.get("private"):
        return [
            {"id": guild, "type": 0, "allow": "0", "deny": str(VIEW)},
            {"id": admin_role, "type": 0, "allow": str(VIEW | SEND), "deny": "0"},
            {"id": bot_user, "type": 1, "allow": str(VIEW | SEND), "deny": "0"},
        ]
    return []


def ensure_channel(guild, spec, existing, admin_role, bot_user):
    have = existing.get(spec["name"])
    if have:
        return have["id"], "kept"
    reuse = existing.get(spec.get("reuse", ""))
    if reuse:
        c = api("PATCH", f"/channels/{reuse['id']}",
                {"name": spec["name"], "topic": spec["topic"]})
        return c["id"], f"renamed from #{spec['reuse']}"
    c = api("POST", f"/guilds/{guild}/channels", {
        "name": spec["name"], "type": 0, "topic": spec["topic"],
        "permission_overwrites": overwrites(spec, guild, admin_role, bot_user),
    })
    return c["id"], "created"


def ensure_rules_message(channel):
    if api("GET", f"/channels/{channel}/messages?limit=1"):
        return "kept"
    api("POST", f"/channels/{channel}/messages", {"content": RULES_TEXT})
    return "posted"


def ensure_automod(guild, admin_role, staff):
    have = {r["name"] for r in api("GET", f"/guilds/{guild}/auto-moderation/rules")}
    block = {"type": 1}
    alert = {"type": 2, "metadata": {"channel_id": staff}}
    rules = [
        {"name": "keyword presets", "trigger_type": 4,
         "trigger_metadata": {"presets": [1, 2, 3]}, "actions": [block]},
        {"name": "mention spam", "trigger_type": 5,
         "trigger_metadata": {"mention_total_limit": 10},
         "actions": [block, alert]},
        {"name": "spam", "trigger_type": 3, "actions": [block, alert]},
    ]
    out = []
    for r in rules:
        if r["name"] in have:
            out.append((r["name"], "kept"))
            continue
        r.update({"event_type": 1, "enabled": True,
                  "exempt_roles": [admin_role]})
        api("POST", f"/guilds/{guild}/auto-moderation/rules", r)
        out.append((r["name"], "created"))
    return out


def ensure_icon(guild, guild_json):
    """The mark on the tile, set once and left alone after that.

    Discord names an icon by a hash of its own making rather than of the
    bytes, so there is no way to ask whether the one up there is this file.
    Setting it every run would churn the audit log to answer a question
    nobody asked, and an icon somebody deliberately changed is not drift this
    script should undo. So: absent, or asked for with --icon.
    """
    if guild_json.get("icon") and "--icon" not in sys.argv:
        return "kept (--icon to replace)"
    if not ICON.exists():
        return f"skipped, no {ICON.name}; run icon.py"
    data = base64.b64encode(ICON.read_bytes()).decode()
    api("PATCH", f"/guilds/{guild}", {"icon": "data:image/png;base64," + data})
    return "set from icon.png"


def ensure_invite(hangar):
    for inv in api("GET", f"/channels/{hangar}/invites"):
        if inv["max_age"] == 0 and inv["max_uses"] == 0:
            return inv["code"], "kept"
    inv = api("POST", f"/channels/{hangar}/invites",
              {"max_age": 0, "max_uses": 0, "unique": True})
    return inv["code"], "created"


def main():
    guild, guild_name = pick_guild()
    bot_user = api("GET", "/users/@me")["id"]
    print(f"server: {guild_name} ({guild})")

    admin_role, note = ensure_role(guild, "admin")
    print(f"role  : admin ({note})")

    existing = {c["name"]: c for c in api("GET", f"/guilds/{guild}/channels")}
    ids = {}
    for spec in CHANNELS:
        ids[spec["name"]], note = ensure_channel(
            guild, spec, existing, admin_role, bot_user)
        print(f"chan  : #{spec['name']} ({note})")

    print(f"rules : message ({ensure_rules_message(ids['rules'])})")

    # Two passes on the guild itself: the safety floor Community insists on,
    # then Community, which needs the channels above to already exist.
    api("PATCH", f"/guilds/{guild}", {
        "verification_level": 2,
        "explicit_content_filter": 2,
        "default_message_notifications": 1,
        "system_channel_id": ids["hangar"],
    })
    print("guild : verification medium, content filter on, "
          "notifications mentions-only, joins land in #hangar")

    guild_json = api("GET", f"/guilds/{guild}")
    print(f"icon  : {ensure_icon(guild, guild_json)}")

    features = guild_json["features"]
    if "COMMUNITY" in features:
        print("guild : community (kept)")
    else:
        api("PATCH", f"/guilds/{guild}", {
            "features": features + ["COMMUNITY"],
            "rules_channel_id": ids["rules"],
            "public_updates_channel_id": ids["staff"],
        })
        print("guild : community enabled; rules -> #rules, "
              "updates -> #staff")

    for spec in CHANNELS:
        if spec.get("news"):
            c = api("GET", f"/channels/{ids[spec['name']]}")
            if c["type"] != 5:
                api("PATCH", f"/channels/{ids[spec['name']]}", {"type": 5})
                print(f"chan  : #{spec['name']} is now an announcement channel")

    for name, note in ensure_automod(guild, admin_role, ids["staff"]):
        print(f"automod: {name} ({note})")

    code, note = ensure_invite(ids["hangar"])
    print(f"invite: https://discord.gg/{code} ({note})")
    print()
    print("left for a human: assign the admin role to the second admin, and")
    print("point the vectorwake.net/discord redirect in")
    print(f"deploy/caddy/conf.d/central.caddy at discord.gg/{code}.")


if __name__ == "__main__":
    TOKEN = os.environ.get("DISCORD_BOT_TOKEN") or sys.exit(
        "DISCORD_BOT_TOKEN is not set")
    main()
