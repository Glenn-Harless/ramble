#!/usr/bin/env python3
"""Ramble MCP server: lets Claude read your Ramble meeting transcripts, notes and dictations.

Read-only, local, standard library only (works with macOS's built-in /usr/bin/python3).
Speaks the Model Context Protocol over stdio (newline-delimited JSON-RPC 2.0).

Data it reads:
  ~/Documents/Ramble Notes/Meetings/YYYY-MM-DD HHmm Meeting.md   meeting transcripts
  ~/Documents/Ramble Notes/YYYY-MM-DD.md                        dictated notes
  ~/Library/Application Support/Ramble/history.jsonl            dictations pasted at the cursor
Override with RAMBLE_NOTES_DIR and RAMBLE_SUPPORT_DIR (used by the tests).
"""
import datetime as dt
import json
import os
import re
import sys

VERSION = "1.0"
HOME = os.path.expanduser("~")
NOTES_DIR = os.environ.get("RAMBLE_NOTES_DIR") or os.path.join(HOME, "Documents", "Ramble Notes")
SUPPORT_DIR = os.environ.get("RAMBLE_SUPPORT_DIR") or os.path.join(HOME, "Library", "Application Support", "Ramble")
MEETINGS_DIR = os.path.join(NOTES_DIR, "Meetings")
HISTORY_FILE = os.path.join(SUPPORT_DIR, "history.jsonl")

MEETING_NAME = re.compile(r"^(\d{4}-\d{2}-\d{2}) (\d{2})(\d{2}) (.+)\.md$")
NOTE_NAME = re.compile(r"^(\d{4}-\d{2}-\d{2})\.md$")
SPEAKER_LINE = re.compile(r"^\*\*(.+?)\*\* · (\d+:\d{2}(?::\d{2})?)\s*$")
MINUTES = re.compile(r"^\*(\d+) min\b")


class ToolError(Exception):
    pass


# ---------------------------------------------------------------- reading files

def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def parse_day(value, field="date"):
    """Accepts YYYY-MM-DD, 'today' or 'yesterday'. Returns a date, or None for empty input."""
    if value in (None, ""):
        return None
    v = str(value).strip().lower()
    today = dt.date.today()
    if v == "today":
        return today
    if v == "yesterday":
        return today - dt.timedelta(days=1)
    try:
        return dt.datetime.strptime(v[:10], "%Y-%m-%d").date()
    except ValueError:
        raise ToolError("%s must look like 2026-11-18, 'today' or 'yesterday' (got %r)" % (field, value))


def in_range(day, since, until):
    return (since is None or day >= since) and (until is None or day <= until)


def word_count(text):
    return len(re.findall(r"\b[\w']+\b", text))


def parse_meeting(path):
    """Splits a Ramble meeting file into its header and speaker turns."""
    name = os.path.basename(path)
    m = MEETING_NAME.match(name)
    started = dt.datetime.strptime(m.group(1) + m.group(2) + m.group(3), "%Y-%m-%d%H%M")
    text = read_text(path)
    lines = text.splitlines()
    title = lines[0].lstrip("# ").strip() if lines and lines[0].startswith("#") else m.group(4)
    minutes = None
    turns = []  # [speaker, timestamp, text]
    for line in lines[1:]:
        mm = MINUTES.match(line)
        if mm and minutes is None and not turns:
            minutes = int(mm.group(1))
            continue
        sm = SPEAKER_LINE.match(line)
        if sm:
            turns.append([sm.group(1), sm.group(2), ""])
        elif turns and line.strip():
            turns[-1][2] = (turns[-1][2] + " " + line.strip()).strip()
    words = {}
    for speaker, _, said in turns:
        words[speaker] = words.get(speaker, 0) + word_count(said)
    return {
        "id": name[:-3],
        "path": path,
        "started": started,
        "title": title,
        "minutes": minutes,
        "turns": turns,
        "words": words,
        "text": text,
    }


def all_meetings():
    if not os.path.isdir(MEETINGS_DIR):
        return []
    found = []
    for name in os.listdir(MEETINGS_DIR):
        if MEETING_NAME.match(name):
            try:
                found.append(parse_meeting(os.path.join(MEETINGS_DIR, name)))
            except (OSError, ValueError):
                continue
    found.sort(key=lambda mt: (mt["started"], mt["id"]), reverse=True)
    return found


def note_files():
    if not os.path.isdir(NOTES_DIR):
        return []
    days = []
    for name in os.listdir(NOTES_DIR):
        m = NOTE_NAME.match(name)
        if m:
            days.append((dt.datetime.strptime(m.group(1), "%Y-%m-%d").date(), os.path.join(NOTES_DIR, name)))
    days.sort(reverse=True)
    return days


def note_entries(day, path):
    """Each '## HH:mm' section of a daily notes file is one entry."""
    entries = []
    current = None
    for line in read_text(path).splitlines():
        m = re.match(r"^## (\d{1,2}:\d{2})\s*$", line)
        if m:
            current = [m.group(1), ""]
            entries.append(current)
        elif current is not None and line.strip():
            current[1] = (current[1] + " " + line.strip()).strip()
    return entries


def history_entries():
    entries = []
    if not os.path.exists(HISTORY_FILE):
        return entries
    with open(HISTORY_FILE, encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                e = json.loads(line)
                e["when"] = dt.datetime.fromtimestamp(float(e["ts"]))
                entries.append(e)
            except (ValueError, KeyError, TypeError):
                continue
    return entries


# ---------------------------------------------------------------- formatting

def fmt_when(d):
    return d.strftime("%a %b %-d %Y, %-I:%M %p")


def meeting_summary_line(mt):
    me = mt["words"].get("Me", 0)
    them = sum(n for s, n in mt["words"].items() if s != "Me")
    length = ("%d min" % mt["minutes"]) if mt["minutes"] is not None else "length unknown"
    first = next((t[2] for t in mt["turns"] if t[2]), "")
    if len(first) > 140:
        first = first[:140].rsplit(" ", 1)[0] + "…"
    return "- id: %s\n  when: %s · %s · %d words (Me %d, Them %d)\n  opens with: %s" % (
        mt["id"], fmt_when(mt["started"]), length, me + them, me, them, first or "(no speech)")


def snippet(text, terms, width=320):
    """A window of text around the first matched term."""
    if len(text) <= width:
        return text
    low = text.lower()
    hits = [low.find(t) for t in terms if low.find(t) >= 0]
    at = min(hits) if hits else 0
    start = max(0, at - width // 3)
    end = min(len(text), start + width)
    out = text[start:end].strip()
    return ("…" if start > 0 else "") + out + ("…" if end < len(text) else "")


# ---------------------------------------------------------------- tools

def find_meeting(meeting_id):
    meetings = all_meetings()
    if not meetings:
        raise ToolError("There are no Ramble meeting transcripts yet (looked in %s)." % MEETINGS_DIR)
    key = (meeting_id or "latest").strip()
    if key.lower() in ("latest", "last", "most recent"):
        return meetings[0]
    key = os.path.basename(key)
    if key.endswith(".md"):
        key = key[:-3]
    for mt in meetings:
        if mt["id"] == key:
            return mt
    # A bare date: fine when exactly one meeting happened that day.
    try:
        day = parse_day(key, "id")
    except ToolError:
        day = None
    if day:
        same = [mt for mt in meetings if mt["started"].date() == day]
        if len(same) == 1:
            return same[0]
        if len(same) > 1:
            raise ToolError("%d meetings on %s, pick one id:\n%s" % (
                len(same), day, "\n".join(meeting_summary_line(mt) for mt in same)))
    raise ToolError("No meeting with id %r. Use list_meetings to see the ids." % meeting_id)


def tool_list_meetings(args):
    since = parse_day(args.get("since"), "since")
    until = parse_day(args.get("until"), "until")
    limit = max(1, min(int(args.get("limit") or 20), 200))
    meetings = [mt for mt in all_meetings() if in_range(mt["started"].date(), since, until)]
    if not meetings:
        return "No Ramble meetings found%s." % (" in that date range" if since or until else "")
    shown = meetings[:limit]
    head = "%d meeting%s%s, newest first:" % (
        len(meetings), "" if len(meetings) == 1 else "s",
        "" if len(shown) == len(meetings) else " (showing %d)" % len(shown))
    return head + "\n" + "\n".join(meeting_summary_line(mt) for mt in shown)


def tool_read_meeting(args):
    mt = find_meeting(args.get("id"))
    return "id: %s\nfile: %s\n\n%s" % (mt["id"], mt["path"], mt["text"].strip())


def tool_read_notes(args):
    day = parse_day(args.get("date") or "today")
    path = os.path.join(NOTES_DIR, day.isoformat() + ".md")
    if not os.path.exists(path):
        recent = ", ".join(d.isoformat() for d, _ in note_files()[:10])
        return "No dictated notes on %s.%s" % (day.isoformat(), (" Days with notes: " + recent) if recent else "")
    return "file: %s\n\n%s" % (path, read_text(path).strip())


def tool_search(args):
    query = (args.get("query") or "").strip()
    if not query:
        raise ToolError("query is required")
    scope = (args.get("scope") or "all").lower()
    if scope not in ("all", "meetings", "notes", "dictations"):
        raise ToolError("scope must be all, meetings, notes or dictations")
    since = parse_day(args.get("since"), "since")
    until = parse_day(args.get("until"), "until")
    limit = max(1, min(int(args.get("limit") or 20), 100))
    terms = [t for t in re.findall(r"[\w']+", query.lower()) if t]
    if not terms:
        raise ToolError("query has no words to search for")

    units = []  # (when, label, text)
    if scope in ("all", "meetings"):
        for mt in all_meetings():
            if not in_range(mt["started"].date(), since, until):
                continue
            for speaker, stamp, said in mt["turns"]:
                units.append((mt["started"], "meeting %s · %s at %s" % (mt["id"], speaker, stamp), said))
    if scope in ("all", "notes"):
        for day, path in note_files():
            if not in_range(day, since, until):
                continue
            for stamp, said in note_entries(day, path):
                when = dt.datetime.combine(day, dt.datetime.strptime(stamp, "%H:%M").time())
                units.append((when, "note %s %s" % (day.isoformat(), stamp), said))
    if scope in ("all", "dictations"):
        for e in history_entries():  # notes and meetings are already searched from their files
            if e.get("mode") == "paste" and in_range(e["when"].date(), since, until):
                units.append((e["when"], "dictation " + e["when"].strftime("%Y-%m-%d %H:%M"), e.get("text", "")))

    def matched(text):
        low = text.lower()
        return sum(1 for t in terms if re.search(r"\b" + re.escape(t), low))

    scored = [(matched(text), when, label, text) for when, label, text in units]
    exact = [s for s in scored if s[0] == len(terms)]
    note = ""
    if exact:
        hits = exact
    else:
        hits = [s for s in scored if s[0] > 0]
        if hits and len(terms) > 1:
            note = "No passage has every word, so these match some of them.\n"
    if not hits:
        return "Nothing in Ramble matches %r." % query
    hits.sort(key=lambda s: (s[0], s[1]), reverse=True)
    out = ["%d match%s for %r%s:" % (len(hits), "" if len(hits) == 1 else "es", query,
                                      "" if len(hits) <= limit else " (showing %d)" % limit)]
    for _, when, label, text in hits[:limit]:
        out.append("- [%s] %s" % (label, snippet(text, terms)))
    return note + "\n".join(out)


DATE_HELP = "YYYY-MM-DD, 'today' or 'yesterday'"
TOOLS = [
    {
        "name": "list_meetings",
        "description": "List the user's Ramble meeting transcripts (recorded calls), newest first, with date, "
                       "length, word counts and the opening line. Use the returned id with read_meeting.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "since": {"type": "string", "description": "Only meetings on or after this day (%s)." % DATE_HELP},
                "until": {"type": "string", "description": "Only meetings on or before this day (%s)." % DATE_HELP},
                "limit": {"type": "integer", "description": "Most to return (default 20)."},
            },
        },
        "annotations": {"title": "List meetings", "readOnlyHint": True, "openWorldHint": False},
        "run": tool_list_meetings,
    },
    {
        "name": "read_meeting",
        "description": "Read one full Ramble meeting transcript as Markdown. 'Me' is the user (their microphone); "
                       "'Them' is everyone else on the call combined. Timestamps are minutes:seconds from the start.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "description": "A meeting id from list_meetings, a day (YYYY-MM-DD) "
                                                        "with one meeting, or 'latest' (default)."},
            },
        },
        "annotations": {"title": "Read meeting", "readOnlyHint": True, "openWorldHint": False},
        "run": tool_read_meeting,
    },
    {
        "name": "search_ramble",
        "description": "Search everything the user has said into Ramble: meeting transcripts, dictated notes, and "
                       "text they dictated into other apps. Returns matching passages with where and when they "
                       "came from. Passages containing every word rank first.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Words to look for (case-insensitive)."},
                "scope": {"type": "string", "enum": ["all", "meetings", "notes", "dictations"],
                          "description": "Where to look (default all)."},
                "since": {"type": "string", "description": "Only on or after this day (%s)." % DATE_HELP},
                "until": {"type": "string", "description": "Only on or before this day (%s)." % DATE_HELP},
                "limit": {"type": "integer", "description": "Most passages to return (default 20)."},
            },
            "required": ["query"],
        },
        "annotations": {"title": "Search Ramble", "readOnlyHint": True, "openWorldHint": False},
        "run": tool_search,
    },
    {
        "name": "read_notes",
        "description": "Read the user's dictated notes for one day (each entry is headed by the time it was said).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "date": {"type": "string", "description": "The day (%s). Default today." % DATE_HELP},
            },
        },
        "annotations": {"title": "Read notes", "readOnlyHint": True, "openWorldHint": False},
        "run": tool_read_notes,
    },
]
TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}

INSTRUCTIONS = (
    "Ramble is the user's local dictation and meeting-recording app. These tools read its meeting transcripts, "
    "dictated notes and dictation history from this Mac. For questions about a call, start with list_meetings "
    "(or read_meeting with id 'latest'); to find where something was discussed, use search_ramble."
)


# ---------------------------------------------------------------- protocol

def respond(msg_id, result=None, error=None):
    out = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        out["error"] = error
    else:
        out["result"] = result
    sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle(msg):
    method = msg.get("method")
    params = msg.get("params") or {}
    if method == "initialize":
        return {
            "protocolVersion": params.get("protocolVersion") or "2025-06-18",
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "ramble", "title": "Ramble", "version": VERSION},
            "instructions": INSTRUCTIONS,
        }
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [{k: v for k, v in t.items() if k != "run"} for t in TOOLS]}
    if method == "tools/call":
        tool = TOOLS_BY_NAME.get(params.get("name"))
        if tool is None:
            raise LookupError("Unknown tool: %s" % params.get("name"))
        try:
            text = tool["run"](params.get("arguments") or {})
            return {"content": [{"type": "text", "text": text}]}
        except (ToolError, OSError, ValueError) as e:
            return {"content": [{"type": "text", "text": str(e)}], "isError": True}
    if method in ("resources/list", "prompts/list"):
        return {method.split("/")[0]: []}
    raise NotImplementedError(method)


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            respond(None, error={"code": -32700, "message": "Parse error"})
            continue
        if not isinstance(msg, dict) or "method" not in msg:
            continue  # a response or junk; we never send requests
        is_request = "id" in msg
        try:
            result = handle(msg)
            if is_request:
                respond(msg["id"], result)
        except NotImplementedError:
            if is_request:
                respond(msg["id"], error={"code": -32601, "message": "Method not found: %s" % msg.get("method")})
        except LookupError as e:
            if is_request:
                respond(msg["id"], error={"code": -32602, "message": str(e)})
        except Exception as e:  # keep serving after a bug
            sys.stderr.write("ramble-mcp: %r\n" % e)
            if is_request:
                respond(msg["id"], error={"code": -32603, "message": "Internal error: %s" % e})


if __name__ == "__main__":
    main()
