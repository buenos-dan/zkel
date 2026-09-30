;;; zk.el --- Personal Zettelkasten notes and planning in Org -*- lexical-binding: t; -*-

;; Author: buenos-dan
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: outlines, convenience
;; URL: https://github.com/buenos-dan/zkel

;;; Commentary:
;; Personal Zettelkasten notes and planning in Org.

;;; Code:

;; Data stays in ordinary Org files.  No database, sync service or network calls.
(require 'org)
(require 'org-agenda)
(require 'org-capture)
(require 'org-id)
(require 'transient)
(require 'button)
(require 'face-remap)
(require 'seq)
(require 'cl-lib)
(require 'subr-x)
(defvar consult-ripgrep-args)
(declare-function vertico-mode "vertico" (&optional arg))
(declare-function marginalia-mode "marginalia" (&optional arg))

(defgroup zk nil "Notes and plans, with visible actions." :group 'org)
(defcustom zk-root (expand-file-name "~/Zettelkasten/")
  "Existing knowledge library." :type 'directory)
(defcustom zk-inbox-file
  (if (file-exists-p (expand-file-name "~/.notes"))
      (expand-file-name "~/.notes")
    (expand-file-name "org-notes/my-inbox.org" zk-root))
  "Quick capture destination, shared with the existing task workflow." :type 'file)
;; Keep the existing recovery location across the package rename.
(defcustom zk-state-directory (locate-user-emacs-file "notebook-state/")
  "Local recovery files; never placed in the note library." :type 'directory)
(defcustom zk-text-height 180
  "Reading size in tenths of a point; code buffers keep their existing font."
  :type 'integer)
(defvar zk--previous-agenda-files nil)
(defvar zk--configured nil)
(defvar-local zk--face-cookie nil)

(defface zk-title '((t (:height 1.9 :weight bold))) "Dashboard title.")
(defface zk-section '((t (:height 1.15 :weight bold))) "Section heading.")
(defface zk-muted '((t (:inherit shadow))) "Supporting text.")
(defface zk-accent '((t (:inherit link :weight bold :underline nil))) "Action.")

(require 'zk-dashboard)

(defun zk--path (relative)
  (expand-file-name relative zk-root))

(defun zk--files-in (directory regexp)
  "Find actual documents, excluding Emacs lock and auto-save files."
  (when (file-directory-p directory)
    (seq-filter (lambda (file)
                  (not (string-match-p "\\`[.#]" (file-name-nondirectory file))))
                (directory-files-recursively directory regexp))))

(defun zk--org-file-p ()
  (and buffer-file-name
       (or (equal (expand-file-name buffer-file-name)
                  (expand-file-name zk-inbox-file))
           (file-in-directory-p buffer-file-name zk-root))))

(defun zk--button (label command &optional help)
  (insert-text-button label 'follow-link t 'face 'zk-accent
                      'help-echo (or help label)
                      'action (lambda (_) (call-interactively command))))

(defun zk--header-action (label command)
  (propertize label 'face 'zk-accent 'mouse-face 'highlight
              'help-echo label
              'local-map (let ((map (make-sparse-keymap)))
                           (define-key map [header-line mouse-1]
                             (lambda (event) (interactive "e")
                               (select-window (posn-window (event-start event)))
                               (call-interactively command)))
                           map)))

(defun zk--header ()
  (list "  " (zk--header-action "ZK" #'zk-home) "    "
        (zk--header-action "+ Add task" #'zk-capture-task) "    "
        (zk--header-action "Today" #'zk-today) "    "
        (zk--header-action "Search" #'zk-search) "    "
        (zk--header-action "Commands · C-c n" #'zk-menu)))

(defun zk--reading-setup ()
  (when (zk--org-file-p)
    (visual-line-mode 1)
    (org-indent-mode 1)
    (setq-local org-hide-emphasis-markers t
                org-pretty-entities t
                line-spacing 0.22
                left-margin-width 2 right-margin-width 2
                header-line-format '(:eval (zk--header))
                auto-save-default t
                make-backup-files t
                backup-inhibited nil
                backup-directory-alist
                `(("." . ,(expand-file-name "backups/" zk-state-directory))))
    (auto-save-mode 1)
    (when zk--face-cookie (face-remap-remove-relative zk--face-cookie))
    (setq zk--face-cookie
          (face-remap-add-relative 'default :height zk-text-height))
    (font-lock-flush)))

(defun zk-refresh-agenda ()
  "Include tasks in every Org note, alongside the existing agenda sources."
  (setq org-agenda-files
        (delete-dups
         (append zk--previous-agenda-files
                 (seq-filter #'file-exists-p (list zk-inbox-file))
                 (zk--files-in (zk--path "org-notes") "\\.org\\'")))))

(defun zk--save-capture ()
  (zk-refresh-agenda)
  (zk-dashboard-request-refresh))

(defun zk-capture-task (title)
  "Collect a task with one plain-language prompt; no Org syntax required."
  (interactive "sNew task: ")
  (when (string-empty-p (string-trim title)) (user-error "Enter a task first"))
  (make-directory (file-name-directory zk-inbox-file) t)
  (let ((org-capture-templates
         `(("N" "Capture" entry (file+headline ,zk-inbox-file "Tasks")
            "* TODO %i\n:PROPERTIES:\n:CREATED: %U\n:END:\n"
            :immediate-finish t :empty-lines 1))))
    (org-capture-string (replace-regexp-in-string "[\n\r]+" " " title) "N"))
  (zk-refresh-agenda)
  (zk-dashboard-refresh)
  (message "Saved to inbox. Press i to review or t for today."))

(defun zk--new-file (file contents)
  "Create FILE only if absent; never overwrite an existing or live document."
  (make-directory (file-name-directory file) t)
  (unless (or (file-exists-p file) (get-file-buffer file))
    (write-region contents nil file nil 'silent nil 'excl))
  (find-file file)
  (zk-refresh-agenda)
  (zk-dashboard-refresh))

(defun zk-new-note (title)
  "Start writing a titled note in the existing library."
  (interactive "sNote title: ")
  (setq title (string-trim (replace-regexp-in-string "[\n\r]+" " " title)))
  (when (string-empty-p title) (user-error "Enter a note title"))
  (let* ((slug (replace-regexp-in-string "[^[:alnum:]_-]+" "-" title))
         (base (zk--path
                (concat "org-notes/" (format-time-string "%Y%m%d-%H%M%S-")
                        (substring slug 0 (min 70 (length slug))))))
         (file (concat base ".org")) (n 1))
    (while (or (file-exists-p file) (get-file-buffer file))
      (setq file (format "%s-%d.org" base n) n (1+ n)))
    (zk--new-file file
                        (format "#+title: %s\n#+date: %s\n#+filetags: :note:\n\n"
                                title (format-time-string "[%Y-%m-%d %a]")))
    (goto-char (point-max))))

(defun zk-daily ()
  "Open today's journal, reusing it on subsequent visits."
  (interactive)
  (zk--new-file
   (zk--path (format-time-string "org-notes/daily/%Y-%m-%d.org"))
   (format "#+title: %s · Daily note\n#+filetags: :daily:\n\n* Today's focus\n\n* Notes\n\n* Review\n- What did I finish?\n- What should carry over to tomorrow?\n"
           (format-time-string "%Y-%m-%d")))
  (goto-char (point-min)))

(defun zk-weekly ()
  "Open a week-based plan with review prompts and ordinary Org headings."
  (interactive)
  (zk--new-file
   (zk--path (format-time-string "org-notes/plans/%G-W%V.org"))
   (format "#+title: %s · Weekly review\n#+filetags: :weekly:\n\n* Outcomes\n** Outcome one\n** Outcome two\n** Outcome three\n\n* Next actions\n\n* Weekly review\n- [ ] Review the inbox\n- [ ] Review completed and open tasks\n- [ ] Follow up on waiting tasks\n- [ ] Choose next week's three outcomes\n\n* Reflections\n"
           (format-time-string "%G · W%V")))
  (goto-char (point-min)))

(defun zk--note-files ()
  (cl-loop for dir in '("org-notes" "md-notes")
           when (file-directory-p (zk--path dir))
           append (zk--files-in (zk--path dir) "\\.\\(org\\|md\\)\\'")))

(defun zk--choose-note ()
  (let ((choices
         (mapcar (lambda (note)
                   (cons (format "%s  —  %s" (plist-get note :title)
                                 (file-relative-name (plist-get note :file) zk-root))
                         (plist-get note :file)))
                 (zk-dashboard--notes))))
    (unless choices (user-error "No notes yet; use C-c n n to create one"))
    (cdr (assoc (completing-read "Open note: " choices nil t) choices))))

(defun zk-find-note ()
  "Find notes by name, including existing Markdown notes."
  (interactive) (find-file (zk--choose-note)))

(defun zk-search ()
  "Search the library with live previews when Consult is available."
  (interactive)
  (if (and (fboundp 'consult-ripgrep) (executable-find "rg"))
      (let ((consult-ripgrep-args
             (if (stringp consult-ripgrep-args)
                 (concat consult-ripgrep-args " -g '*.org' -g '*.md'")
               (append consult-ripgrep-args '("-g" "*.org" "-g" "*.md")))))
        (consult-ripgrep zk-root))
    (require 'grep)
    (rgrep (read-string "Search: ") "*.org *.md" zk-root)))

(defun zk-insert-link ()
  "Insert an ordinary Org file link to an existing note."
  (interactive)
  (unless (derived-mode-p 'org-mode) (user-error "Insert links from an Org note"))
  (let ((file (zk--choose-note)))
    (insert (org-link-make-string
             (concat "file:" (file-relative-name file default-directory))
             (plist-get (zk-dashboard--metadata file) :title)))))

(defun zk-today ()
  (interactive) (zk-refresh-agenda) (org-agenda nil "N"))

(defun zk-week ()
  (interactive) (zk-refresh-agenda) (org-agenda nil "W"))

(defun zk-inbox ()
  (interactive)
  (let ((org-agenda-files
         (seq-filter #'file-exists-p
                     (list zk-inbox-file (zk--path "org-notes/my-inbox.org"))))
        (org-agenda-overriding-header "Inbox · Select a task and press x for actions")
        (org-agenda-todo-ignore-scheduled 'all)
        (org-agenda-todo-ignore-deadlines 'all))
    (org-todo-list "TODO")))

(defun zk--entry ()
  (when (derived-mode-p 'zk-home-mode) (zk-dashboard-open-task))
  (when (derived-mode-p 'org-agenda-mode) (org-agenda-switch-to))
  (unless (derived-mode-p 'org-mode) (user-error "Select an Org heading or task first"))
  (when (org-before-first-heading-p) (user-error "Move to an Org heading first"))
  (org-back-to-heading t))

(defun zk--edit-entry (action)
  "Run ACTION on the selected task, preserving earlier unsaved source edits.
Save automatically when the source was clean.  Return non-nil when it
already had unsaved edits, leaving those edits and this action in memory."
  (let (pending)
    (let ((edit (lambda ()
                  (setq pending (buffer-modified-p))
                  (funcall action)
                  (unless pending (save-buffer)))))
      (if (derived-mode-p 'zk-home-mode)
          (let ((marker (zk-dashboard-task-marker)))
            (with-current-buffer (marker-buffer marker)
              (save-excursion
                (save-restriction
                  (widen) (goto-char marker) (funcall edit)))))
        (zk--entry)
        (funcall edit)))
    (zk-dashboard-refresh)
    pending))

(defun zk--state (state)
  (if (zk--edit-entry (lambda () (org-todo state)))
      (message "Task updated in memory; the source note has unsaved edits.")
    (message "Task saved. Use undo in the source note to revert.")))

(defun zk-next () (interactive) (zk--state "NEXT"))
(defun zk-hold () (interactive) (zk--state "HOLD"))
(defun zk-done () (interactive) (zk--state "DONE"))
(defun zk-reset () (interactive) (zk--state "TODO"))
(defun zk-schedule ()
  (interactive) (zk--edit-entry (lambda () (call-interactively #'org-schedule))))
(defun zk-deadline ()
  (interactive) (zk--edit-entry (lambda () (call-interactively #'org-deadline))))
(defun zk-priority ()
  (interactive) (zk--edit-entry (lambda () (call-interactively #'org-priority))))
(defun zk-refile ()
  (interactive) (zk--entry) (call-interactively #'org-refile)
  (zk-dashboard-refresh))

(transient-define-prefix zk-item-menu ()
  "Actions for the selected task or Org heading."
  [["Status"
    ("n" "Next action · NEXT" zk-next)
    ("h" "Waiting / paused · HOLD" zk-hold)
    ("d" "Complete · DONE" zk-done)
    ("r" "Back to inbox · TODO" zk-reset)]
   ["Plan and organize"
    ("s" "Schedule" zk-schedule)
    ("e" "Deadline" zk-deadline)
    ("p" "Priority" zk-priority)
    ("m" "Refile to another heading" zk-refile)]] )

(defvar-local zk--focus-state nil)
(defun zk-focus ()
  "Toggle a focused view, preserving the previous window configuration."
  (interactive)
  (if zk--focus-state
      (let ((state zk--focus-state))
        (setq zk--focus-state nil)
        (set-window-configuration state))
    (setq zk--focus-state (current-window-configuration))
    (delete-other-windows)
    (let ((margin (max 2 (/ (- (window-total-width) 88) 2))))
      (set-window-margins nil margin margin)))
  (message "C-c n z toggles focus and restores your previous windows."))

(transient-define-prefix zk-menu ()
  "Write notes and manage tasks."
  [["Capture and write"
    ("c" "Add task → Inbox" zk-capture-task)
    ("n" "New note" zk-new-note)
    ("d" "Daily note" zk-daily)
    ("l" "Insert note link" zk-insert-link)]
   ["Plan and act"
    ("t" "Today" zk-today)
    ("i" "Inbox" zk-inbox)
    ("w" "Week" zk-week)
    ("p" "Weekly review" zk-weekly)]
   ["Navigate"
    ("h" "ZK" zk-home)
    ("f" "Find note" zk-find-note)
    ("s" "Full-text search" zk-search)
    ("x" "Task actions…" zk-item-menu)
    ("z" "Focus mode" zk-focus)]] )

(defun zk--agenda-setup ()
  (setq-local line-spacing 0.18 header-line-format '(:eval (zk--header)))
  (local-set-key (kbd "x") #'zk-item-menu))

(defun zk--menu-setup ()
  (when (memq transient-current-command '(zk-menu zk-item-menu))
    (face-remap-add-relative 'default :height zk-dashboard-text-height)
    (setq-local line-spacing 0.12)))

(defun zk-setup ()
  "Install the interaction layer.  Safe to load again."
  (unless zk--configured
    (setq zk--previous-agenda-files (org-agenda-files)
          zk--configured t))
  (make-directory (expand-file-name "backups" zk-state-directory) t)
  (make-directory (expand-file-name "autosaves" zk-state-directory) t)
  ;; Existing init disabled recovery globally.  Enable it only for this library.
  (dolist (path (list zk-root zk-inbox-file))
    (add-to-list 'auto-save-file-name-transforms
                 `(,(concat "\\`" (regexp-quote path) ".*\\'")
                   ,(expand-file-name "autosaves/" zk-state-directory) t)))
  (add-to-list 'auto-mode-alist
               `(,(concat "\\`" (regexp-quote zk-inbox-file) "\\'") . org-mode))
  (setq org-todo-keywords '((sequence "TODO(t)" "NEXT(n)" "HOLD(h)" "|" "DONE(d)" "CANCELLED(c)"))
        org-log-done 'time
        org-log-into-drawer t
        org-startup-folded 'content
        org-return-follows-link t
        org-agenda-window-setup 'current-window
        org-agenda-span 'week
        org-agenda-start-on-weekday 1
        org-agenda-skip-scheduled-if-done t
        org-agenda-skip-deadline-if-done t
        org-agenda-todo-ignore-scheduled 'future
        org-agenda-todo-ignore-deadlines 'far
        org-refile-use-outline-path 'file
        org-outline-path-complete-in-steps nil
        org-refile-targets '((org-agenda-files :maxlevel . 4)))
  (dolist
      (command
       '(("N" "Today"
          ((agenda "" ((org-agenda-span 1)
                       (org-agenda-start-day "+0d")
                       (org-agenda-overriding-header "Today · Scheduled items and deadlines")))
           (todo "NEXT" ((org-agenda-overriding-header "Next actions · Unscheduled, x for actions")
                         (org-agenda-todo-ignore-scheduled 'all)
                         (org-agenda-todo-ignore-deadlines 'all)))
           (todo "HOLD" ((org-agenda-overriding-header "Waiting · Follow up when ready")))))
         ("W" "Week and review"
          ((agenda "" ((org-agenda-span 'week)
                       (org-agenda-start-day nil)
                       (org-agenda-start-with-log-mode t)
                       (org-agenda-overriding-header "This week · Scheduled and completed")))))))
    (setq org-agenda-custom-commands
          (cons command (seq-remove (lambda (old) (equal (car old) (car command)))
                                    org-agenda-custom-commands))))
  ;; Use packages already installed.  No implicit package installation.
  (when (require 'vertico nil t) (vertico-mode 1))
  (when (require 'marginalia nil t) (marginalia-mode 1))
  (when (require 'orderless nil t)
    (setq completion-styles '(orderless basic)
          completion-category-overrides '((file (styles partial-completion basic)))))
  (require 'consult nil t)
  (when (file-executable-p "/opt/homebrew/bin/rg")
    (add-to-list 'exec-path "/opt/homebrew/bin"))
  (global-set-key (kbd "C-c n") #'zk-menu)
  (add-hook 'org-mode-hook #'zk--reading-setup)
  (add-hook 'org-agenda-mode-hook #'zk--agenda-setup)
  (add-hook 'transient-setup-buffer-hook #'zk--menu-setup)
  (add-hook 'org-capture-after-finalize-hook #'zk--save-capture)
  (zk-refresh-agenda)
  ;; Refresh Org's buffer-local keyword cache without reloading or losing edits.
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'org-mode) (zk--org-file-p))
        (org-set-regexps-and-options)
        (zk--reading-setup))))
  (setq initial-buffer-choice #'zk-home))

(zk-setup)
(provide 'zk)
;;; zk.el ends here
