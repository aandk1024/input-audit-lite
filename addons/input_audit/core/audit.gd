@tool
extends RefCounted

## Runs the checks over a project. Kept apart from the dock so every rule can
## be exercised headlessly, with no editor anywhere.

const Actions := preload("res://addons/input_audit/core/actions.gd")
const Checks := preload("res://addons/input_audit/core/checks.gd")
const Scan := preload("res://addons/input_audit/core/scan.gd")


class Result extends RefCounted:
    var findings: Array = []
    ## The project's own actions. Engine defaults the project never declared
    ## are not counted: a report that opens "Actions in the input map: 100" on
    ## a project whose file has nine is not describing that project.
    var actions_checked: int = 0
    var files_read: int = 0
    ## Files that could not be opened. A name used in one of them would look
    ## unused, so this is never treated as nothing.
    var unreadable: Array = []
    ## Call sites whose action name is built at runtime. Not an error; just
    ## the part of the project this tool cannot answer for.
    var dynamic: int = 0
    ## References through an `action` property - one built in code, or the
    ## inspector value on a node in a scene. They count as uses and never as
    ## typos, and the number is said out loud for the same reason `dynamic`
    ## is: some of them are input actions and this tool cannot say which.
    var maybe: int = 0
    ## Everything else that stopped this being a look at the whole project: a
    ## folder that would not open, a depth or budget limit, an action whose
    ## stored events could not be read. Plain sentences, meant to be printed.
    var incomplete: Array = []
    ## Folders skipped because they carry a .gdignore. Deliberate, not a fault.
    var ignored: int = 0
    var ms: int = 0

    ## 🔴 A build server has to be able to tell "clean" from "did not finish".
    ## Anything that means part of the project was not looked at belongs here,
    ## not only a file that failed to open.
    func ok() -> bool:
        return unreadable.is_empty() and incomplete.is_empty()

    ## Every reason this run did not cover the whole project, files included.
    func why_incomplete() -> Array:
        var out: Array = []
        for path in unreadable:
            out.append("could not read the file %s" % String(path))
        for why in incomplete:
            out.append(String(why))
        return out


## Nothing here is asynchronous - no scene is built and no frame is waited on -
## but the signature matches the rest of the family so the dock reads the same.
static func run(root: String = "res://", opts: Object = null) -> Result:
    var res := Result.new()
    var started := Time.get_ticks_msec()
    var options = opts if opts != null else Checks.Options.new()

    var actions := Actions.project_actions(root)
    var found := Scan.scan(root)

    for a in actions.values():
        if a.declared:
            res.actions_checked += 1
        if a.bad_events > 0:
            res.incomplete.append(
                "\"%s\" has %d row(s) in its stored events that are not input events"
                % [a.name, a.bad_events])
    res.files_read = found.files_read
    res.unreadable = found.unreadable.duplicate()
    res.incomplete.append_array(found.incomplete)
    res.ignored = found.ignored.size()
    res.dynamic = found.dynamic.size()
    res.maybe = found.maybe_uses()
    res.findings = Checks.run(actions, found, options)
    _sort(res.findings)
    res.ms = Time.get_ticks_msec() - started
    return res


## Stable order, so two runs over an unchanged project produce identical
## output and a diff of the JSON report means something.
static func _sort(findings: Array) -> void:
    findings.sort_custom(func(a, b):
        if a.kind != b.kind:
            return a.kind < b.kind
        if a.action != b.action:
            return a.action < b.action
        if a.file != b.file:
            return a.file < b.file
        if a.line != b.line:
            return a.line < b.line
        return a.detail < b.detail)
