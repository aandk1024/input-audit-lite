@tool
extends RefCounted

## Turns findings into the three shapes a buyer needs: a summary for the dock,
## Markdown for a ticket, and JSON a build server can fail a pipeline on.
##
## The JSON shape is a contract. It is versioned and its keys are pinned by
## the test suite, because once it is wired into CI a renamed field is a
## broken build rather than a cosmetic change.

const SCHEMA_VERSION := 1

## An action name that does not exist, or one NOTHING can trigger, is a fail:
## something in the game cannot be done at all. The rest are warnings - real,
## and sometimes deliberate.
##
## "Only a pointer can trigger it" is one of those. On a mouse-driven or a
## touch-only game it is the design, and it shares its tick box with
## "nothing bound at all" - so as a fail it left a mobile project no way to
## keep the check that finds a genuinely dead action while still passing a
## build. A warning says the same thing without that.
const SEVERITY := {
    "undefined_action": "fail",
    "no_binding": "fail",
    "pointer_only": "warn",
    "no_gamepad": "warn",
    "no_keyboard": "warn",
    "duplicate_binding": "warn",
    "bad_deadzone": "warn",
    "unused_action": "warn",
}

const KIND_LABEL := {
    "undefined_action": "Action name that does not exist",
    "no_binding": "Action with nothing bound to it",
    "pointer_only": "Action no key or gamepad can trigger",
    "no_gamepad": "No gamepad binding",
    "no_keyboard": "No key bound",
    "duplicate_binding": "One press fires two actions",
    # Not "Unusable": a deadzone of 0 really is unusable, but the upper bound
    # only makes the stick hard to push far enough, and calling that unusable
    # is a claim the finding's own sentence does not make.
    "bad_deadzone": "Extreme gamepad deadzone",
    "unused_action": "Action nothing uses",
}

const KIND_ORDER := [
    "undefined_action", "no_binding", "pointer_only", "no_gamepad",
    "no_keyboard", "duplicate_binding", "bad_deadzone", "unused_action",
]


static func severity_of(kind: String) -> String:
    return String(SEVERITY.get(kind, "warn"))


static func counts(findings: Array) -> Dictionary:
    var out := {"fail": 0, "warn": 0, "total": 0}
    for f in findings:
        var s := severity_of(f.kind)
        out[s] = int(out.get(s, 0)) + 1
        out["total"] = int(out["total"]) + 1
    return out


static func by_kind(findings: Array) -> Dictionary:
    var out := {}
    for f in findings:
        var k: String = f.kind
        if not out.has(k):
            out[k] = []
        out[k].append(f)
    return out


static func to_lines(findings: Array) -> PackedStringArray:
    var out := PackedStringArray()
    var groups := by_kind(findings)
    for k in KIND_ORDER:
        if not groups.has(k):
            continue
        var list: Array = groups[k]
        out.append("%s (%d)" % [KIND_LABEL.get(k, k), list.size()])
        for f in list:
            out.append("  " + f.to_line())
    # A kind added to checks.gd but not registered here would otherwise
    # vanish from every report.
    for k in groups.keys():
        if KIND_ORDER.has(k):
            continue
        var extra: Array = groups[k]
        out.append("%s (%d)" % [KIND_LABEL.get(k, k), extra.size()])
        for f in extra:
            out.append("  " + f.to_line())
    return out


static func summary(findings: Array, actions_checked: int, files_read: int, ms: int) -> String:
    var c := counts(findings)
    if c["total"] == 0:
        return "%d action(s) and %d file(s) checked in %dms - nothing to report" % [
            actions_checked, files_read, ms]
    return "%d action(s) and %d file(s) checked in %dms - %d fail, %d warn" % [
        actions_checked, files_read, ms, c["fail"], c["warn"]]





## Removes a temporary file after a failure. Never touches anything else.
static func _discard(tmp: String) -> void:
    var d := DirAccess.open(tmp.get_base_dir())
    if d != null and d.file_exists(tmp.get_file()):
        d.remove(tmp.get_file())
