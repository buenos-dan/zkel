# zk

Collect raw information, clarify it into projects and actions, and turn useful
ideas into connected knowledge notes. Org files remain the source of truth.

## Workflow

The task states are **TODO → NEXT → DONE**. Waiting or postponed work stays
TODO, with context or a follow-up date when useful. Cancelled work is archived
with its cancellation recorded, rather than counted as completed.

1. **Capture** anything in `my-inbox.org`. Captures have no automatic TODO
   state, project or date. The Inbox count means unprocessed entries.
2. **Process inbox** daily. Move an entry to an agenda area/project as a task,
   project or event; extract it as a knowledge note; or archive it.
3. **Select NEXT** from the organized project tree. NEXT means ready to act;
   it does not require a scheduled date. TODO is the organized backlog; DONE means completed.
4. Complete actions using Org's transitions and repeaters. Choose the next
   action explicitly instead of automatically advancing a dependent task.
5. Link tasks/projects to notes and use backlinks to reconnect ideas.

`my-agenda.org` organizes areas (Work, Life, Finance, etc.) with projects and
actions below them. Existing outline containers are valid destinations;
new projects have `ZK_TYPE: project`. Calendar events can have no TODO keyword.

The `*ZK*` dashboard shows **Agenda**, **Todos**, **Inbox**, and **Notes**.
Todos, Inbox entries and notes use compact tables with project/date,
source/capture date, and tags/update date columns. The Notes table displays
file names including extensions, rather than document titles or first headings. Narrow windows hide
secondary columns. Titles use normal text colors; primary controls use a
subtle theme accent, and metadata uses muted text. Links remain clickable.
Columns align to fixed display positions, including mixed Chinese and Latin
text. Graphical Emacs truncates long cells by actual glyph width, without
changing fonts or font sizes; terminal Emacs uses character-cell widths.
Agenda embeds the native Org Agenda day or week: date headings, time grid,
current-time marker, event colors, repeaters and diary expressions. Calendar
rows are never limited by the preview count; click an event to open its source.
Completed-item visibility follows the global Org Agenda settings, including
`org-agenda-skip-scheduled-if-done`, `org-agenda-skip-deadline-if-done` and
`org-agenda-skip-timestamp-if-done`. Set them to nil to retain completed items
on their original dates. Notes excludes the two workflow files. Todos shows
all NEXT tasks followed by today's DONE tasks in one table; unprocessed Inbox
items never appear there. NEXT uses amber and DONE uses gray. NEXT tasks are
ordered by priority, then source order; completed tasks show newest completion
first. There is no Todos preview limit.

Today's completions are determined by Org's `CLOSED` timestamp, independently
of scheduled or deadline dates. ZK enables `org-log-done` and `org-log-repeat`
with time logging. Repeating tasks use today's `LAST_REPEAT` plus an Org DONE
log: the completed occurrence is displayed as DONE even if Org has already
reset the source to TODO. If it is set to NEXT, it appears once as NEXT and
keeps Org's advanced repeat date. Old DONE entries without a completion timestamp
are not guessed to have finished today.

## Installation and configuration

Emacs 30.1 or newer is required. The repository is `zkel`, the package is `zk`.

```elisp
(use-package zk
  :ensure nil
  :vc (:url "https://github.com/buenos-dan/zkel.git"
       :branch "main" :rev :newest :main-file "zk.el")
  :demand t
  :bind ("C-c n" . zk-menu)
  :config
  (zk-mode 1)
  (setq initial-buffer-choice #'zk-home))
```

`require` loads definitions without installing settings or hooks. `zk-mode`
provides the shared Org experience: indented headings, hidden leading stars,
`…` folding markers, inline images by default, muted blue TODO, amber NEXT and neutral gray DONE
states. Completed items remain on their original Agenda dates. These preferences
apply to existing and future Org buffers, including files outside the library.
Fonts and font sizes continue to follow Emacs defaults.

`zk-org.el` owns this presentation and the default TODO sequence. Explicit file
TODO sequences and `#+STARTUP: noinlineimages` remain usable; leading-star and
indentation presentation stays consistent across Org files. Org source text and
folding are preserved. `zk-org-store.el` owns parsing, IDs, edits and transactions.

`zk-mode` also sets `org-agenda-files`, `org-default-notes-file`, and
`remember-data-file` from the library paths. These path bindings and the
library's backup/autosave and ID-navigation integration stay separate from
global Org formatting. Home has no header line or fringes.

Disabling `zk-mode` removes its hooks/advice and restores the settings it owns.
Settings explicitly changed after activation are retained. Repeated activation
does not duplicate display hooks. Keep package installation, personal keybindings
and optional `initial-buffer-choice` in `init.el`; no `init-org.el` is needed.

Configure the options before enabling `zk-mode` (for example with `:custom`
in `use-package`). Restart the mode after changing presentation options.

Defaults:

```elisp
(setq zk-root "~/Zettelkasten/"
      zk-inbox-file "org-notes/my-inbox.org"
      zk-agenda-file "org-notes/my-agenda.org"
      zk-org-note-directory "org-notes/"
      zk-markdown-note-directory "md-notes/"
      zk-home-item-limit 8
      zk-org-indent-width 2
      zk-org-ellipsis "…"
      zk-org-inline-images t
      zk-org-keep-completed t)
```

Inbox and Notes show eight entries by default. Inbox uses collection time
(newest first, undated entries last); Notes uses file modification time
(newest first). Todos always shows all current NEXT and today's DONE entries.

Paths can be absolute or relative to `zk-root`. No daily/plans or database
directory is created. Date-based journaling can remain ordinary headings in
the shared documents; it is not imposed as a separate workflow.

## Keys

From `*ZK*`, use the keys directly; elsewhere open `C-c n`.

| Key | Action |
| --- | --- |
| `i` | In Todos: browse project tasks to add NEXT; in Inbox: edit a new item |
| `Esc` | Return from the Todos project tree to the Daily table |
| `a` | Open Agenda |
| `t` | Change an Agenda or Todos task's state with native Org selection |
| `C-c C-s` / `C-c C-d` | Schedule / deadline for the Agenda entry |
| `d` / `w` | Switch day / week inside Home’s Agenda section |
| `y` | Open the current calendar year in a standalone Org Agenda buffer |
| `x` | Task status and dates |
| `n` / `p` | Move down / up one line |
| `C-c n n` | Create a note through the command menu |
| `f` | Find a note by filename |
| `s` | Search |
| `TAB` | Fold a project branch, or expand / collapse Inbox and Notes |
| `RET` | Open the entry or activate the action |
| `M-n` / `M-p` | Move forward / backward between actions |
| `g` / `?` | Refresh / command menu |

On an Agenda entry, `t` uses `org-agenda-todo`; on a Todos row, it uses `org-todo`
on the original heading. Both preserve Org's state selection, logging, repeaters
and blockers. Use `t d` to finish or `t n` to reopen a completed task as NEXT.
`C-c C-s` and `C-c C-d` use the corresponding native
Agenda commands and accept their normal prefix arguments (for example,
`C-u C-c C-d` removes a deadline). The selected window stays on Home; no Agenda
buffer needs to be opened. Agenda and Todos refresh after the change. Cursor identity, section, row occurrence,
column and window scroll position are retained across immediate and queued
refreshes, including entries without IDs. Clean source
buffers are saved; earlier unsaved edits remain unsaved. Date commands require an
Agenda entry; state changes require a task row. The menu offers the same views through `C-c n d`, `C-c n w`, and `C-c n y`. The shared task APIs remain available to other
commands and Amble; Agenda’s native actions do not use the `zk-done`/`zk-next`
command wrappers.

Home starts in day view. `d` returns to today; `w` shows the current Monday–Sunday
week. Both keys update the Agenda section in place and keep the other Home
sections unchanged. The selected view survives refreshes and task edits. The
section heading shows its date range without shortcut hints. Day and week
projections have independent in-memory caches. The daily API (`zk-today-items`)
continues to return today only, irrespective of the selected Home view.

`y` opens January 1–December 31 of the current year in a native Org Agenda
buffer. Empty days and time-grid rows are omitted there. Returning to Home
retains its previous day/week selection. `zk-week` now selects Home’s week view;
it no longer jumps to a standalone Agenda buffer.

The Todos heading distinguishes **Daily** and **Projects**. Press `i` anywhere
in Todos to browse the actual hierarchy from `my-agenda.org`, in source order.
Groups start folded and show TODO/NEXT counts. Entering from a task reveals its
ancestors. Use `TAB` to open or close a branch, `n`/`p` to move, and `t n` to
promote TODO to NEXT. The row stays in the tree so several tasks can be selected.
`Esc` returns to Daily, focusing the selected task when it belongs in that table.
Re-entering Projects restores its selection and folds. Archived/commented
branches and branches without TODO/NEXT tasks are excluded. `i` outside Todos
and Inbox asks you to move to one of those sections.

In Inbox and Notes, TAB works anywhere in a table, including its heading and
rows. Collapsing from a hidden row returns to that table's heading. The dashboard
does not display Show all/less buttons or TAB hints. Agenda and Daily Todos
always show their complete views. These bindings apply only to `*ZK*`; Org
folding and the Inbox review screen keep their own TAB behavior.

`f` searches Org and Markdown filenames using case-insensitive substring
matching: `mac`, `MAC`, or `configuration` can find `org-notes/mac-configuration.org`.
Relative directories disambiguate duplicate filenames. Candidate generation does
not read document contents, and it leaves global completion settings unchanged.

The menu also provides project creation, ID links and backlinks.
RET anywhere on a Todos row, including its state prefix, opens the source.
State prefixes are labels; changes happen through `t`.

## Creating notes

Each note is one file. `C-c n n` / `zk-new-note` asks only for a filename, including
its extension; it does not ask for a title or add a timestamp prefix.

| Input | Destination |
| --- | --- |
| `mac-configuration.org` | `org-notes/mac-configuration.org` |
| `quick-idea.md` | `md-notes/quick-idea.md` |

Names may contain Chinese characters or spaces. Include `.org` or `.md` and
omit directory components. Existing files and open drafts are never overwritten.

An Org note starts with file-level properties and a blank body. No `#+TITLE`
or wrapper heading is added. `ID` is unique, `DATE` is today's date, and the
other initial values are:

```org
:PROPERTIES:
:ID: <generated UUID>
:ZK_TYPE: fleeting-note
:MDS: nil
:TOPICS: nil
:DATE: YYYY-MM-DD
:END:
```

Markdown notes start empty unless body text is supplied through the API, and
keep their normal Markdown major mode.

`zk-note-create FILENAME &optional BODY` follows the same routing rules.
`zk-inbox-to-note REF FILENAME` takes an `.org` filename: it preserves Org
content, properties, tags and IDs, moves the source ID to the file level, and
promotes child headings instead of retaining a wrapper heading. It does not
convert Inbox content to Markdown.

## Inbox workspace

`i` in Home's Inbox section opens `*ZK Inbox*` on the new-item draft with editing
enabled. `M-x zk-process-inbox` opens the same workspace in browse mode.
Clicking a Home Inbox entry or opening from an Inbox heading
selects that item. The left queue appears in wide windows; `j` selects
items in any window size. `+ New item` remains available even when Inbox is empty.

The message starts in read-only **Browse** mode. Single-letter keys operate the
workspace. Press `e` (or click Edit) to enter **Editing** mode; letters then type
normally, Return inserts a newline, and TAB keeps its Org behavior. Press `Esc`
or `C-c C-c` to finish editing and return to browsing. Finishing retains a draft
without writing documents; `RET` in Browse saves it (`C-x C-s` can save directly
while editing). Switching items, creating a new draft or saving successfully
returns to Browse mode. The mode line shows the current mode.

The first nonempty line is the summary, followed by optional body text, links
and headings. Root properties are kept separately; child headings and their IDs
remain in the body. Settings are in a separate panel, so changing them never
replaces the text or clears undo history.

Choose **Inbox**, **Agenda**, or **Archive**. Each option and Agenda field
shows its keyboard shortcut. Note creation uses the command menu (`C-c n n`), outside Inbox:

- **Inbox** saves a raw new message or edits an existing message in place.
  New messages have no inferred TODO, project or date.
- **Agenda** expands Type, Location, State, Scheduled and Deadline controls.
  Tasks default to TODO; NEXT is an explicit choice. Dates are optional
  for tasks, required for events, and scheduling never promotes a task to NEXT.
  Location can select or create an area/project. The last destination appears
  as a suggestion, never silently as the next item's destination.
- **Archive** (`a` or its button) immediately archives the current message,
  including edited text, and advances to the next item. No extra save is needed.

`RET` in Browse (also `C-x C-s`) executes the visible primary action: **Save to Inbox**,
**Save changes**, **Save to Agenda**, or **Move to Agenda**.
New direct Agenda items never create an intermediate Inbox
copy. Editing and moving an existing message happens in one transaction.
Validation failures highlight the relevant setting and retain the text.

| Key in Browse | Action |
| --- | --- |
| `e` | Enter text editing |
| `c` | Switch to the new-message draft (press `e` to type) |
| `i` / `p` | Choose Inbox / Agenda |
| `a` | Archive the current item immediately and advance |
| `d` | Choose Location or create an area/project |
| `t` / `w` | Choose Type / State |
| `s` / `l` | Set Scheduled / Deadline using Org's calendar |
| `S` / `L` | Clear Scheduled / Deadline |
| `RET` / `C-x C-s` | Apply the visible save action |
| `]` / `[` (also `M-n` / `M-p`) | Next / previous Inbox item |
| `j` / `/` | Select an item / filter the visible queue |
| `o` / `v` | Open source / last saved result |
| `g` | Reload current source, confirming before discarding edits |
| `q` | Return to the previous layout, retaining drafts |

In the read-only queue and settings panels, single-letter actions stay available;
Return activates the selected button. In the text editor, `Esc` or `C-c C-c`
finishes editing. Neither key submits or discards the draft.

New-message saves clear the composer for another capture. Moving an existing
message advances to the next item; saving edits to Inbox keeps it selected.
Every item retains its own text, settings and cursor position while switching.
Drafts live in the Emacs session. Returning does not discard them; killing the
workspace or exiting Emacs asks before discarding unsaved drafts.

Earlier unsaved edits in source documents remain unsaved. If a transaction
commits but saving fails, the UI reports the save error and does not offer the
same creation again. Source revision conflicts keep the draft until an explicit
reload. No journal, backup or persistent draft directory is created.

## Core API

UI commands and Amble use the same APIs. Core writes do not switch windows.

| API | Purpose |
| --- | --- |
| `zk-inbox-submit TEXT &rest OPTIONS` | Create/edit and route atomically; first line is the summary |
| `zk-capture TITLE &optional BODY REQUEST-ID` | Raw collection, optional retry deduplication |
| `zk-inbox-entries` | Pending entries |
| `zk-projects` / `zk-project-create` | Area/project destinations |
| `zk-inbox-process REF DEST &rest PROPERTIES` | Move into an organized task, project or event |
| `zk-tasks &optional STATE` | Actions with project/area context |
| `zk-tasks-overview` | Daily NEXT/today's DONE records and project tree with TODO/NEXT counts |
| `zk-task-update REF &rest PROPERTIES` | Status and dates with revision checking |
| `zk-org-edit-todo REF &optional PREFIX` | Native Org state selection on a checked source snapshot |
| `zk-entry-read REF` | Full source subtree for an observed entry |
| `zk-note-create FILENAME` / `zk-inbox-to-note REF FILENAME` | Create or extract a knowledge file |
| `zk-backlinks` | Find ID references in library documents |
| `zk-inbox-archive` | Recoverable removal into Agenda's Archive subtree |
| `zk-today-items` | Native calendar projection |

Snapshots contain ID (when present), file, position and a subtree content
revision. Existing entries receive IDs when explicitly changed, never during
queries. IDs survive moves; unrelated sibling edits do not invalidate a task's
revision. Writes reject stale snapshots. File-level Org IDs also remain usable.

`zk-inbox-process` accepts `:kind` (`task`, `project`, `event`), `:title`, `:state`,
`:scheduled` and `:deadline`. An event requires its real schedule. Tasks may
remain undated. Date inputs use `YYYY-MM-DD [HH:MM[-HH:MM]] [+1w]`; `++` and
`.+` repeaters are also accepted. Existing diary expressions are left to Org.
For updates, nil leaves a date unchanged; an empty string removes it.

Writes are grouped across affected buffers and validated before saving. Clean
buffers are saved; earlier unsaved work remains in memory. Results report
`:saved` and `:save-errors`. A save or UI-refresh failure does not repeat the
operation. If `:saved` is nil, save/reconcile the affected documents instead of
recapturing or reprocessing the entry. Original sources are preserved on edit
failure. No Git commits or pushes are automatic.

## Modules and boundaries

| Module | Responsibility |
| --- | --- |
| `zk.el` | Package entry, integration hooks and mode lifecycle |
| `zk-library.el` | Library settings, paths, file discovery, change notifications |
| `zk-org.el` | Global Org presentation, colors, default state sequence and reversible settings |
| `zk-org-store.el` | Org entry snapshots, ID lookup, edits, dates and transactions |
| `zk-tasks.el` | Agenda projects, task queries and task updates |
| `zk-notes.el` | Note-file records, cached metadata, creation and backlinks |
| `zk-inbox.el` | Raw capture and all processing outcomes, including notes and archive |
| `zk-agenda.el` | Native Org Agenda views and cached calendar rows |
| `zk-ui.el` | Shared selection, date input and record navigation |
| `zk-commands.el` | User-facing commands and transient menus |
| `zk-inbox-review.el` | Editable Inbox workspace, per-item drafts, queue and settings |
| `zk-home.el` | Home tables, selection, expansion and refresh coordination |

Dependencies flow from the library and Org primitives into workflow modules,
then shared interaction and screens. Every module loads independently. Shared
operations have public names; a module's `--` functions remain internal.
Commands load the Inbox workspace on demand. Requiring `zk` installs no
hooks or timers; `zk-mode` explicitly enables integration. Home owns its timers.

Inbox processing owns the transaction that moves content between documents.
Tasks and notes provide destination operations; `zk-org-take-subtree` and
`zk-org-insert-subtree` provide shared Org editing primitives. These primitives
must run inside a transaction, never as independent UI commands.

Amble's `amble-zk.el` uses the same public workflow APIs. It contains no separate
TODO storage or workflow implementation. Org presentation belongs in `zk-org.el`;
Emacs-wide font settings, personal keys and the startup buffer remain user choices.

## Records and references

Records are plists with an explicit `:record` discriminator:

| Record | Fields and meaning |
| --- | --- |
| `entry` | An Org heading or file-level Org entry: `:scope`, `:id`, `:file`, `:position`, `:revision`, plus task/outline fields |
| `note` | A whole knowledge file: `:scope file`, `:file`, `:filename`, `:title`, `:id`, `:tags`, `:mtime`, `:modified`, `:revision` |
| `link` | A backlink occurrence: `:file`, `:line`, `:text` |

Note creation, extraction and listing return the same whole-file record shape.
An operation additionally returns `:saved` and `:save-errors`. Preserve `:scope`
when passing a reference back to the API. A note's revision covers its entire
file; a heading's revision covers its subtree. A note ID comes from its file
properties or first root heading, never an unrelated later heading.

`zk-org-locate` locates identity for navigation. `zk-org-resolve` additionally
checks a snapshot's revision before a write. `zk-entry-read` reads current
contents, including the whole file for a note reference. Opening an entry is
not blocked by a stale edit snapshot; writes still reject it. Review previews
retain explicit conflict checking before a pending operation is applied.

Review drafts, selection and expansion are screen state, not saved document
properties. Core operations neither select windows nor depend on screen state.

`zk-org-todo-keywords` is the single Org state sequence used by parsing,
transition validation and the full state chooser. The quick-action buttons
expose the workflow's common TODO and NEXT choices.

## Refresh behavior

The clock updates the selected Agenda view without querying notes or Inbox.
At the Org day boundary it also refreshes Todos to expire yesterday's completions. File
notifications update only the affected sections. Resizing redraws the tables
and reflows the native Agenda for its new width, without rescanning notes.
TAB changes the projection using existing data. Explicit `g` refresh clears
caches and queries everything, including changes made outside Emacs.

Note metadata is cached by file modification/change time, size and live-buffer
version. Unsaved edits invalidate the corresponding record; they remain
unsaved. Calendar caching belongs to `zk-agenda.el`. Both caches live only in
memory and do not create an index or state directory.

## Tests

```sh
emacs -Q --batch -l tests/run-tests.el
```

`zk-test-helper.el` owns temporary-library fixtures. The runner discovers the
module suites, including Inbox review, layout, record contracts and cache
invalidation. Fixtures never use the real knowledge library. The Amble adapter
has its own integration tests in the Amble repository.

The startup suite activates ZK in a fresh Emacs without `-L`, then loads the
package and enables its mode. This also checks that installed autoloads register
their own directory. When regenerating autoloads manually, use
`package-generate-autoloads`, which supplies package activation setup:

```sh
emacs -Q --batch --eval '(progn (require (quote package)) (package-generate-autoloads "zk" default-directory))'
```
