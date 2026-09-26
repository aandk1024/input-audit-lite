@tool
extends RefCounted

## Finds every place the project names an input action.
##
## Two sources, because an action can be named in either and a check that only
## looked at one would call a used action unused:
##
##   .gd    Input.is_action_pressed("jump"), get_axis(), get_vector(),
##          event.is_action("fire"), InputMap.has_action(), and the rest
##   .tscn  an InputEventAction resource, which is how a shortcut or a
##   .tres  remapping table names an action without any code at all
##
## Only names written as a literal are checked. A call whose argument is a
## variable cannot be resolved without running the game, so it is counted and
## reported as a number rather than guessed at. A checker that quietly ignores
## what it cannot read is how "no problems found" stops meaning anything.

## Folders never walked. "addons" is NOT one of them: an action used only by
## another plugin would otherwise look like an action nothing uses, and a
## checker whose headline finding is "delete this" must not be wrong about it.
## Our own folder is skipped by name in _walk(), because this addon's demo
## strings are not the buyer's code.
const SKIP_DIRS := [".godot", ".git", ".import", "android", "ios"]
const OWN_ADDON := "input_audit"
const MAX_DEPTH := 40
const MAX_DIRS := 20000
const CODE_EXT := ["gd"]
const SCENE_EXT := ["tscn", "tres"]


class Ref extends RefCounted:
    var action: String = ""
    var file: String = ""
    var line: int = 0
    ## The call or property the name was found in, for the report.
    var via: String = ""
    ## Whether this reference actually presses, reads or fakes the action.
    ## InputMap bookkeeping - has_action(), erase_action(), the deadzone
    ## getters - names an action without ever using it as input, so it must
    ## not be what saves an action from "nothing uses this".
    var uses: bool = true
    ## Whether it was found inside somebody else's addon. Those names belong
    ## to that plugin: they count as uses, but a name only they mention is
    ## not the buyer's typo to fix.
    var in_addon: bool = false
    ## Whether this really is an input action rather than something that
    ## merely looks like one.
    ##
    ## An `action` property - `e.action = "fire"` on an InputEventAction built
    ## in code, or the inspector value of an @export var action on a node in a
    ## scene - names an action the same way a call does, and cannot be typed
    ## from the text: a quest resource's own `action` property has the same
    ## shape. So it is recorded, and marked uncertain.
    ##
    ## Uncertain is enough to stop "Action nothing uses", which is the finding
    ## that gets working input deleted, and deliberately not enough to raise
    ## "Action name that does not exist", which would send the reader to
    ## change a line that was already right.
    var certain: bool = true

    func where() -> String:
        return "%s:%d" % [file, line]


class Found extends RefCounted:
    ## action name -> Array[Ref]
    var refs: Dictionary = {}
    ## Action names the project adds at runtime with InputMap.add_action().
    ## They are not in the project file and must not be called undefined.
    var added: Dictionary = {}
    ## Call sites whose action name is not a literal, as Array[Ref] with an
    ## empty action.
    var dynamic: Array = []
    var files_read: int = 0
    ## Files that could not be opened at all. Never counted as clean.
    var unreadable: Array = []
    ## Reasons the walk did not see the whole project: a folder that could not
    ## be opened, a depth limit, a folder budget. Anything in here means the
    ## run is NOT complete, and the reports must say so - "no problems found"
    ## over half a project is the one output worse than none.
    var incomplete: Array = []
    ## Folders deliberately skipped because they carry a .gdignore. Not an
    ## error; still worth saying out loud.
    var ignored: Array = []

    func names() -> Array:
        var out: Array = refs.keys()
        out.sort()
        return out

    func add(r: Ref) -> void:
        if not refs.has(r.action):
            refs[r.action] = []
        refs[r.action].append(r)

    ## Whether any reference to this name actually uses it as input.
    func used_as_input(name: String) -> bool:
        if not refs.has(name):
            return false
        for r in refs[name]:
            if r.uses:
                return true
        return false

    ## References that name an action without proving it is one - an `action`
    ## property in code or on a node in a scene. Reported as a number, the
    ## same way a name built at runtime is, because the honest answer is that
    ## some of them are input actions and this tool cannot say which.
    func maybe_uses() -> int:
        var n := 0
        for name in refs.keys():
            for r in refs[name]:
                if not r.certain:
                    n += 1
        return n

    ## Whether any reference to this name is in the buyer's own code rather
    ## than inside another plugin.
    func named_outside_addons(name: String) -> bool:
        if not refs.has(name):
            return false
        for r in refs[name]:
            if not r.in_addon:
                return true
        return false


## Methods on the Input singleton. method name -> the argument positions that
## are action names (0-based).
const INPUT_CALLS := {
    "is_action_pressed": [0],
    "is_action_just_pressed": [0],
    "is_action_just_released": [0],
    "is_action_released": [0],
    "get_action_strength": [0],
    "get_action_raw_strength": [0],
    "action_press": [0],
    "action_release": [0],
    "get_axis": [0, 1],
    "get_vector": [0, 1, 2, 3],
}

## Methods on an InputEvent. These are the only ones allowed on an ordinary
## variable, because an event is normally held in one.
const EVENT_CALLS := {
    "is_action": [0],
    "is_action_pressed": [0],
    "is_action_released": [0],
    # An analogue read off the event itself. Missing it made an action that a
    # game genuinely uses come back as an action nothing uses, which is the one
    # finding that gets working input deleted.
    "get_action_strength": [0],
}

## Methods on the InputMap singleton that ASK about or EDIT an action without
## ever using it as input. InputMap.has_action("x") does not mean the game can
## press x.
const MAP_CALLS := {
    "has_action": [0],
    "erase_action": [0],
    "action_get_events": [0],
    "action_has_event": [0],
    "action_add_event": [0],
    "action_erase_event": [0],
    "action_erase_events": [0],
    "action_set_deadzone": [0],
    "action_get_deadzone": [0],
}

## The one method on InputMap that USES an action rather than asking about it
## or editing it: it answers whether this event is that action, which is what
## event.is_action() does with the arguments the other way round. Left out of
## MAP_CALLS, it would have been bookkeeping - and an action a project reads
## only this way would have come back as an action nothing uses.
const MAP_USES := {
    "event_is_action": [1],
}

## An existence probe. A name here is being tested, not asserted, so a name
## the map does not have is the answer rather than a typo.
const PROBES := ["has_action"]

## Calls that create an action rather than use one.
const CREATES := {"add_action": [0]}

## Every name above, for the first, cheap "is this word interesting" test.
static func _slot_for(word: String, receiver: String) -> Array:
    # Input.<x>() - the ordinary way a game reads an action.
    if receiver == "Input" and INPUT_CALLS.has(word):
        return [INPUT_CALLS[word], "use"]
    if receiver == "InputMap":
        if CREATES.has(word):
            return [CREATES[word], "create"]
        if MAP_USES.has(word):
            return [MAP_USES[word], "use"]
        if MAP_CALLS.has(word):
            return [MAP_CALLS[word], "manage"]
        # InputMap.action_press() does not exist; nothing else is claimed.
        return []
    if receiver == "" or receiver == "?":
        # No plain identifier in front of the dot. FakeInput.new().is_action_
        # pressed("ghost") lands here, and a class of somebody else's that
        # merely borrows the method name is not an input action reference.
        return []
    # Some other variable. Only the InputEvent methods are plausible.
    if EVENT_CALLS.has(word):
        return [EVENT_CALLS[word], "use"]
    return []


static func scan(root: String = "res://") -> Found:
    var f := Found.new()
    var files := PackedStringArray()
    _walk(root, files, 0, [], f)
    # Sorted, so the report is byte-identical between runs.
    files.sort()
    for path in files:
        var text = _read(String(path))
        if text == null:
            f.unreadable.append(String(path))
            continue
        f.files_read += 1
        if String(path).get_extension().to_lower() == "gd":
            _scan_code(String(path), String(text), f)
        else:
            _scan_scene(String(path), String(text), f)
    return f


static func _read(path: String):
    if not FileAccess.file_exists(path):
        return null
    var fh := FileAccess.open(path, FileAccess.READ)
    if fh == null:
        return null
    var text := fh.get_as_text()
    fh.close()
    return text


static func _walk(path: String, out: PackedStringArray, depth: int = 0,
        budget: Array = [], f: Found = null) -> void:
    if budget.is_empty():
        budget.append(MAX_DIRS)
    if depth > MAX_DEPTH:
        var deep := "stopped at %d folders deep (%s) - a folder link probably points at one of its own parents" % [MAX_DEPTH, path]
        push_error("input_audit: " + deep + ". The scan is NOT complete.")
        _note(f, deep)
        return
    if int(budget[0]) <= 0:
        return
    budget[0] = int(budget[0]) - 1
    if int(budget[0]) == 0:
        var many := "stopped after %d folders" % MAX_DIRS
        push_error("input_audit: " + many + ". The scan is NOT complete.")
        _note(f, many)
        return
    var d := DirAccess.open(path)
    if d == null:
        _note(f, "could not open the folder %s" % path)
        return
    if FileAccess.file_exists(path.path_join(".gdignore")):
        if f != null:
            f.ignored.append(path)
        return
    d.list_dir_begin()
    var name := d.get_next()
    while name != "":
        if name.begins_with("."):
            name = d.get_next()
            continue
        var full := path.path_join(name)
        if d.current_is_dir():
            if SKIP_DIRS.has(name) or _is_link(d, full):
                name = d.get_next()
                continue
            # This addon's own folder. Its demo strings are not the buyer's.
            if name == OWN_ADDON and path.get_file() == "addons":
                name = d.get_next()
                continue
            _walk(full, out, depth + 1, budget, f)
        else:
            var ext := name.get_extension().to_lower()
            if CODE_EXT.has(ext) or SCENE_EXT.has(ext):
                out.append(full)
        name = d.get_next()
    d.list_dir_end()


static func _note(f: Found, why: String) -> void:
    if f != null and not f.incomplete.has(why):
        f.incomplete.append(why)


static func _is_link(d: DirAccess, full: String) -> bool:
    if not d.has_method("is_link"):
        return false
    return bool(d.call("is_link", full))


# --- code ----------------------------------------------------------------------

## Replaces the contents of comments with spaces, leaving the length and every
## newline exactly where they were so line numbers stay true.
##
## The point of doing it properly rather than with a regex: a "#" inside a
## string is not a comment, and a "#" in a comment can be followed by a quote,
## which a naive pass would read as the start of a string and then swallow the
## rest of the file - including real calls.
static func strip_comments(text: String) -> String:
    # Built as chunks and joined once. A String in GDScript cannot be written
    # to by index, and appending one character at a time to a String copies
    # the whole thing every time, which is measurable on a large project.
    var parts: Array = []
    var kept := 0
    var i := 0
    var n := text.length()
    while i < n:
        var c := text[i]
        if c == "#":
            var j := i
            while j < n and text[j] != "\n":
                j += 1
            parts.append(text.substr(kept, i - kept))
            parts.append(" ".repeat(j - i))
            kept = j
            i = j
            continue
        if c == "\"" or c == "'":
            # A triple quote runs to the next triple quote, newlines included.
            var triple := (i + 2 < n and text[i + 1] == c and text[i + 2] == c)
            var quote := c
            if triple:
                i += 3
                while i + 2 < n and not (text[i] == quote and text[i + 1] == quote and text[i + 2] == quote):
                    i += 1
                i = min(i + 3, n)
                continue
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote or text[i] == "\n":
                    i += 1
                    break
                i += 1
            continue
        i += 1
    parts.append(text.substr(kept, n - kept))
    return "".join(PackedStringArray(parts))


static func _scan_code(path: String, raw: String, f: Found) -> void:
    var in_addon := path.contains("/addons/")
    var text := strip_comments(raw)
    var n := text.length()
    var i := 0
    # The line number of the character at `line_pos`. Counting newlines from
    # the start of the file for every reference made a generated file with
    # thousands of calls take time proportional to the square of its length -
    # 3000 calls measured at 22 seconds - and that time is spent inside the
    # editor's own frame. Both cursors only ever move forwards, so the whole
    # file is walked once.
    var line_pos := 0
    var line_no := 1
    while i < n:
        var c := text[i]
        # A string body is not code. strip_comments() cannot blank one, because
        # the action names this scanner reads are themselves strings - so a
        # line of GDScript quoted inside another string used to be scanned as
        # if it were a call.
        if c == "\"" or c == "'":
            i = _skip_string(text, i)
            continue
        if not _is_ident_start(c):
            i += 1
            continue
        var start := i
        while i < n and _is_ident_char(text[i]):
            i += 1
        var word := text.substr(start, i - start)
        if word == PROP_NAME:
            # x.action = "fire" - the way an InputEventAction is built in code
            # and pushed through Input.parse_input_event(), and the way a
            # handler reads back which action an event was. Neither is a call,
            # so a scanner that only read call arguments called an action a
            # project really presses an action nothing uses.
            var pr = _property_ref(text, start, i, path, in_addon)
            if pr != null:
                while line_pos < start:
                    if text[line_pos] == "\n":
                        line_no += 1
                    line_pos += 1
                pr.line = line_no
                f.add(pr)
            continue
        if not (INPUT_CALLS.has(word) or EVENT_CALLS.has(word)
                or MAP_CALLS.has(word) or MAP_USES.has(word) or CREATES.has(word)):
            continue
        var found := _slot_for(word, _receiver(text, start))
        if found.is_empty():
            continue
        var slot: Array = found[0]
        var role := String(found[1])
        # A local variable or a member called is_action_pressed is not a call.
        var j := i
        while j < n and (text[j] == " " or text[j] == "\t"):
            j += 1
        if j >= n or text[j] != "(":
            continue
        var args := _args(text, j)
        while line_pos < start:
            if text[line_pos] == "\n":
                line_no += 1
            line_pos += 1
        for pos in slot:
            if int(pos) >= args.size():
                continue
            var arg: String = String(args[int(pos)]).strip_edges()
            var lit = literal(arg)
            var r := Ref.new()
            r.file = path
            r.line = line_no
            r.via = word
            r.uses = role == "use"
            r.in_addon = in_addon
            if lit == null:
                # A name built at runtime. Counted, never guessed at - but only
                # when the call actually presses or reads the action. Asking
                # InputMap.has_action(n) about a computed name resolves nothing
                # about input, and counting it made every "Action nothing uses"
                # line carry a caveat about a call site that could not have
                # been using anything.
                if role == "use":
                    f.dynamic.append(r)
                continue
            r.action = String(lit)
            if role == "create":
                # Whose code created it. An add_action() inside somebody else's
                # plugin must not excuse a typo in the buyer's own code, so the
                # name is only treated as created when the buyer's own code
                # created it.
                if not bool(f.added.get(r.action, false)):
                    f.added[r.action] = not in_addon
            else:
                f.add(r)
        i = j
    return


## The property an InputEventAction keeps its action name in, and the name a
## generic button script gives an @export var so the inspector can fill it in.
const PROP_NAME := "action"


## A Ref for `<something>.action = "name"` or `<something>.action == "name"`,
## or null when this is not that.
##
## The receiver must be a plain identifier: `e.action`, not `foo().action` and
## not a bare `action = "x"`, which is an ordinary variable in most files. The
## name must be a literal, for the same reason as everywhere else - a computed
## one cannot be resolved without running the game.
##
## `word_end` is the index just past the word "action"; `start` is its first
## character. The line is filled in by the caller, which is the only thing
## that knows where its own cursor is.
static func _property_ref(text: String, start: int, word_end: int, path: String,
        in_addon: bool):
    var recv := _receiver(text, start)
    if recv == "" or recv == "?" or recv == "Input" or recv == "InputMap":
        return null
    var n := text.length()
    var e := word_end
    while e < n and (text[e] == " " or text[e] == "\t"):
        e += 1
    if e >= n or text[e] != "=":
        return null
    # "=" and "==" both read the name. ":=", "!=", "<=" and ">=" have their
    # own character in front and never reach here.
    while e < n and text[e] == "=":
        e += 1
    while e < n and (text[e] == " " or text[e] == "\t"):
        e += 1
    # Exactly the literal, not the rest of the line: `if e.action == "fire":`
    # ends in a colon, and `x.action = "fire" # note` in a comment's blanks,
    # and either one read as part of the value made the whole thing not a
    # literal at all.
    var lead := e
    if e < n and (text[e] == "&" or text[e] == "^" or text[e] == "r"):
        e += 1
    if e >= n or (text[e] != "\"" and text[e] != "'"):
        return null
    var lit = literal(text.substr(lead, _skip_string(text, e) - lead))
    if lit == null or String(lit) == "":
        return null
    var r := Ref.new()
    r.action = String(lit)
    r.file = path
    r.via = "action property"
    r.uses = true
    r.certain = false
    r.in_addon = in_addon
    return r


## The identifier immediately before the dot in front of a call, or "" when
## there is no dot, or "?" when there is a dot but the thing before it is not
## a plain identifier - FakeInput.new().is_action_pressed(), an array index, a
## parenthesised expression.
static func _receiver(text: String, start: int) -> String:
    var k := start - 1
    while k >= 0 and (text[k] == " " or text[k] == "\t"):
        k -= 1
    if k < 0 or text[k] != ".":
        return ""
    k -= 1
    while k >= 0 and (text[k] == " " or text[k] == "\t"):
        k -= 1
    if k < 0 or not _is_ident_char(text[k]):
        return "?"
    var stop := k + 1
    while k >= 0 and _is_ident_char(text[k]):
        k -= 1
    var name := text.substr(k + 1, stop - (k + 1))
    if k >= 0 and text[k] == ".":
        # A.B.method(). The receiver is the end of a path rather than a name
        # on its own, and the two cases pull opposite ways.
        #
        # Something merely CALLED Input inside another object is not the
        # singleton, and reading Global.Input.get_axis("a", "b") as one would
        # invent two action references out of an ordinary call.
        #
        # But self.event.is_action_pressed("jump") is how plenty of code is
        # written, and answering "?" to it - the answer meant for an
        # expression like FakeInput.new() - dropped the reference entirely,
        # which is how an action a project reads every frame came back as an
        # action nothing uses. An ordinary member at the end of a path is
        # treated as what it is: a variable, so only the InputEvent methods
        # are plausible on it.
        if name == "Input" or name == "InputMap":
            return "?"
    return name


## GDScript identifiers are not ASCII. A variable named in Japanese - and this
## is a tool sold to whoever buys it - made _receiver() answer "?", which is
## the answer reserved for an expression, so `変数.is_action_pressed("jump")`
## was not counted as a use at all and its action came back unused.
static func _is_ident_start(c: String) -> bool:
    return ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"
        or c.unicode_at(0) >= 128)


static func _is_ident_char(c: String) -> bool:
    return _is_ident_start(c) or (c >= "0" and c <= "9")


## The comma-separated arguments of the call whose "(" is at open_at, as raw
## text. Nested calls, arrays and dictionaries are stepped over, so
## get_axis(a(1, 2), b) is two arguments rather than three.
static func _args(text: String, open_at: int) -> Array:
    var out: Array = []
    var n := text.length()
    var depth := 0
    var i := open_at
    var arg_start := open_at + 1
    while i < n:
        var c := text[i]
        if c == "\"" or c == "'":
            var quote := c
            # A triple quote is one literal that runs to the next triple
            # quote, and the quotes inside it are content.
            if i + 2 < n and text[i + 1] == quote and text[i + 2] == quote:
                i += 3
                while i + 2 < n and not (text[i] == quote and text[i + 1] == quote and text[i + 2] == quote):
                    i += 1
                i = min(i + 3, n)
                continue
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    break
                i += 1
            i += 1
            continue
        if c == "(" or c == "[" or c == "{":
            depth += 1
            i += 1
            continue
        if c == ")" or c == "]" or c == "}":
            depth -= 1
            if depth == 0:
                out.append(text.substr(arg_start, i - arg_start))
                return out
            i += 1
            continue
        if c == "," and depth == 1:
            out.append(text.substr(arg_start, i - arg_start))
            arg_start = i + 1
            i += 1
            continue
        i += 1
    # Unbalanced: whatever was collected so far, and nothing invented.
    return out


## The text of a string literal, or null when the argument is anything else.
## &"x" (StringName) and ^"x" (NodePath) are accepted because both appear in
## real code passing an action name.
##
## r"x" is a raw string, and the whole point of one is that a backslash in it
## is a backslash. Stripping the r and then decoding escapes anyway turned an
## action really called menu\n into one containing a newline - which is a
## different name, so one call site produced both a typo reported against a
## line that was right and the real action reported as unused.
static func literal(arg: String):
    var s := arg.strip_edges()
    var raw := false
    if s.length() >= 2 and (s[0] == "&" or s[0] == "^" or s[0] == "r"):
        raw = s[0] == "r"
        s = s.substr(1)
    if s.length() < 2:
        return null
    var q := s[0]
    if q != "\"" and q != "'":
        return null
    # """jump""" is one literal in GDScript, and reading it as an empty string
    # followed by rubbish made a used action look unused.
    if s.length() >= 6 and s[1] == q and s[2] == q:
        var tail := s.substr(s.length() - 3)
        if tail == q + q + q:
            var triple_body := s.substr(3, s.length() - 6)
            return triple_body if raw else triple_body.c_unescape()
        return null
    if s[s.length() - 1] != q:
        return null
    var body := s.substr(1, s.length() - 2)
    # A quote inside means this was a concatenation or two arguments that were
    # not separated - not one literal.
    var i := 0
    while i < body.length():
        if body[i] == "\\":
            i += 2
            continue
        if body[i] == q:
            return null
        i += 1
    return body if raw else body.c_unescape()


## The index just past the string literal that starts at `at`. A triple quote
## runs to the next triple quote, newlines included; an ordinary one ends at
## its closing quote, honouring backslash escapes, and cannot cross a newline.
## An unterminated literal ends with the text.
static func _skip_string(text: String, at: int) -> int:
    var n := text.length()
    var quote := text[at]
    var i := at
    if i + 2 < n and text[i + 1] == quote and text[i + 2] == quote:
        i += 3
        while i + 2 < n and not (text[i] == quote and text[i + 1] == quote and text[i + 2] == quote):
            i += 1
        return min(i + 3, n)
    i += 1
    while i < n:
        if text[i] == "\\":
            i += 2
            continue
        if text[i] == quote or text[i] == "\n":
            return i + 1
        i += 1
    return n


## The line an index falls on, counting from the start. Used by the tests and
## by anything that needs one line number rather than a whole file's worth;
## _scan_code() keeps its own forward cursor instead, because calling this once
## per reference is quadratic in the length of the file.
static func _line_of(text: String, index: int) -> int:
    var line := 1
    var i := 0
    var stop := min(index, text.length())
    while i < stop:
        if text[i] == "\n":
            line += 1
        i += 1
    return line


# --- scenes and resources -------------------------------------------------------

## An InputEventAction stored in a .tscn or .tres names its action in a plain
## `action = &"jump"` line. Read as text rather than by loading the resource:
## loading a scene runs its @tool scripts, and a checker must not have side
## effects on the project it is checking.
##
## The section the line sits in decides how much it counts for. `action` is an
## ordinary property name - an @export var action: StringName on a quest
## resource is not an input action, and reporting "open_shop is not in the
## input map" about one is a finding that sends the reader to break working
## data. So the header is tracked:
##
##   [sub_resource type="InputEventAction"]  a certain reference
##   [resource] of a .tres that IS one       a certain reference
##   [node]                                  an uncertain one
##
## A [node] line is where the inspector puts the value of an @export var
## action on a generic button script, which is how a real project binds one
## script to twenty different actions. Skipping it entirely reported every one
## of those actions as an action nothing uses. Reading it as certain would put
## a quest node's own property in front of the reader as a typo. So it is read
## and marked uncertain, which stops the first and cannot cause the second.
##
## Every other section is left alone: an ordinary [resource] is the quest case
## above, and there is no inspector wiring behind it to lose.
static func _scan_scene(path: String, text: String, f: Found) -> void:
    var in_addon := path.contains("/addons/")
    var head := RegEx.new()
    head.compile("^\\[(gd_resource|gd_scene|sub_resource|resource|ext_resource|node|connection|editable)\\b(.*)$")
    var prop := RegEx.new()
    # A stored name can contain an escaped quote - Godot writes it as \" - and
    # stopping at the first one truncated the name into a different action,
    # which then produced both a false "does not exist" and a false "nothing
    # uses this".
    prop.compile("^\\s*action\\s*=\\s*[&^]?\"((?:[^\"\\\\\\n]|\\\\.)*)\"")
    var typ := RegEx.new()
    typ.compile("type\\s*=\\s*\"([^\"]*)\"")

    # A .tres whose own gd_resource type is InputEventAction has its property
    # in the bare [resource] section.
    var file_is_action := false
    var here := false
    var soft := false
    var line_no := 0
    for raw in text.split("\n"):
        line_no += 1
        var line := String(raw).replace("\r", "")
        var h := head.search(line)
        if h != null:
            var kind := h.get_string(1)
            var t := typ.search(h.get_string(2))
            var tname := t.get_string(1) if t != null else ""
            soft = false
            if kind == "gd_resource":
                file_is_action = tname == "InputEventAction"
                here = false
            elif kind == "sub_resource":
                here = tname == "InputEventAction"
            elif kind == "resource":
                here = file_is_action
            else:
                here = false
                soft = kind == "node"
            continue
        if not here and not soft:
            continue
        var m := prop.search(line)
        if m == null:
            continue
        var name := m.get_string(1).c_unescape()
        if name == "":
            continue
        var r := Ref.new()
        r.action = name
        r.file = path
        r.line = line_no
        r.via = "InputEventAction" if here else "action property"
        r.certain = here
        r.in_addon = in_addon
        f.add(r)
