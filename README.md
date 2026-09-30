# zk

A personal Zettelkasten workspace built on ordinary Org and Markdown files.

## Installation

Requires Emacs 30.1 or newer. The repository is named `zkel`; the Emacs
package, feature, and command prefix are `zk`.

Install directly from GitHub with the built-in `use-package :vc` support:

```elisp
;;; ZK — personal Zettelkasten workspace
(use-package zk
  :ensure nil
  :vc (:url "https://github.com/buenos-dan/zkel.git"
       :branch "main"
       :rev :newest
       :main-file "zk.el")
  :demand t
  :bind ("C-c n" . zk-menu))
```

Do not add the old `lisp/zk` directory to `load-path` when using this setup.
Use `M-x package-vc-upgrade RET zk RET` to pull and rebuild later updates.
`M-x zk-home` or `C-c n h` opens the dashboard; `C-c n` opens the command menu.

This is a personal package. Loading it configures Org task states, agenda
views, completion (when optional packages are already installed), and the
startup dashboard. Notes remain in `~/Zettelkasten/` by default. Set
`zk-root` and `zk-inbox-file` with `:init` if your library lives elsewhere.

For development, clone this repository separately and run the tests below.
The package-managed checkout normally lives at `~/.emacs.d/elpa/zk/`.

## Dashboard

| Key | Action |
| --- | --- |
| `c` | Capture a task in the inbox |
| `n` | Create and open an Org note |
| `RET` | Open the selected task or note |
| `TAB` / `S-TAB` | Move between clickable actions |
| `x` | Change the selected task's state, dates, priority, or location |
| `t` / `w` | Open today's / this week's native Org Agenda |
| `i` | Review the inbox |
| `f` / `s` | Find a note by title / search its contents |
| `g` | Refresh |
| `?` | All commands |

Click a task's `[ ]` button to mark it done. Org handles repeating tasks normally.
Editing a task from the dashboard keeps the dashboard selected. Clean source
buffers are saved automatically; existing unsaved changes are left unsaved.

The dashboard groups open tasks by their stored scheduled/deadline dates:
Overdue, Today, Upcoming, Unscheduled, and Waiting. The earliest of scheduled
and deadline dates determines the group; the WHEN column distinguishes the
two, and the tooltip includes both. This is a summary of stored dates. Org
Agenda remains the full view for reminders, scheduling delays, and recurrence.
Completed, commented, and archived trees are excluded. All Org files beneath
`org-notes/`, the inbox, and the pre-existing agenda sources participate.

Groups initially show three tasks, with an explicit Show more action. Notes
show the five most recently edited files. Open unsaved buffers take precedence
over disk content. Titles come from Org `#+title:` or the first Markdown H1,
with the filename as fallback; Org file tags appear when there is room.

Wide windows show task source and note tags. Narrow windows hide these columns;
below 65 characters task state and date move below the title. Existing note
content and note-reading font size are unchanged.

## Appearance

```elisp
(setq zk-dashboard-text-height 130  ; 13 pt, dashboard only
      zk-dashboard-task-limit 3
      zk-dashboard-note-limit 5)
```

The dashboard uses your current theme's faces. After changing font height,
reopen its buffer or run `M-x zk-home-mode` followed by `g`.

## Tests

From this package directory, run:

```sh
emacs -Q --batch -L . -l tests/zk-dashboard-tests.el -f ert-run-tests-batch-and-exit
```

Tests use temporary libraries and do not edit your real notes or init file.
