;;; zk-dashboard.el --- A compact dashboard for zk -*- lexical-binding: t; -*-

;; Author: buenos-dan
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: outlines, convenience
;; URL: https://github.com/buenos-dan/zkel

;;; Commentary:
;; A compact dashboard for zk.

;;; Code:

(require 'org)
(require 'org-agenda)
(require 'button)
(require 'face-remap)
(require 'hl-line)
(require 'seq)
(require 'cl-lib)
(require 'subr-x)

(defvar zk-root)
(defvar zk-inbox-file)
(declare-function zk--note-files "zk")
(declare-function zk-refresh-agenda "zk")
(declare-function zk-capture-task "zk" (title))
(declare-function zk-new-note "zk" (title))
(declare-function zk-today "zk")
(declare-function zk-inbox "zk")
(declare-function zk-week "zk")
(declare-function zk-weekly "zk")
(declare-function zk-daily "zk")
(declare-function zk-find-note "zk")
(declare-function zk-search "zk")
(declare-function zk-menu "zk")
(declare-function zk-item-menu "zk")
(declare-function zk-done "zk")

(defgroup zk-dashboard nil "The zk overview." :group 'zk)
(defcustom zk-dashboard-text-height 130
  "Dashboard font height, in tenths of a point.  Note text is unaffected."
  :type 'integer :group 'zk-dashboard)
(defcustom zk-dashboard-task-limit 3
  "Initially visible tasks per group.  Show more expands that group."
  :type 'natnum :group 'zk-dashboard)
(defcustom zk-dashboard-note-limit 5
  "Number of recently edited notes shown on the dashboard."
  :type 'natnum :group 'zk-dashboard)

(defface zk-dashboard-heading '((t (:weight bold :height 1.15)))
  "Compact section heading." :group 'zk-dashboard)
(defface zk-dashboard-muted '((t (:inherit shadow)))
  "Secondary information." :group 'zk-dashboard)
(defface zk-dashboard-action '((t (:inherit link :underline nil)))
  "Clickable text." :group 'zk-dashboard)
(defface zk-dashboard-overdue '((t (:inherit warning)))
  "Past dates." :group 'zk-dashboard)

(defconst zk-dashboard-buffer-name "*ZK Dashboard*")
(defconst zk-dashboard--groups '("Overdue" "Today" "Upcoming" "Unscheduled" "Waiting"))
(defvar zk-dashboard--metadata-cache (make-hash-table :test #'equal))
(defvar zk-dashboard--refresh-timer nil)
(defvar-local zk-dashboard--tasks nil)
(defvar-local zk-dashboard--notes nil)
(defvar-local zk-dashboard--expanded nil)
(defvar-local zk-dashboard--width nil)

(defun zk-dashboard--plain (text)
  "Keep TEXT on one display line without changing its source."
  (string-trim (replace-regexp-in-string "[\n\r\t]+" " " (or text ""))))

(defun zk-dashboard--metadata (file)
  "Read FILE's title and tags, honoring live edits and caching unchanged files."
  (let* ((file (expand-file-name file))
         (buffer (get-file-buffer file))
         (attrs (file-attributes file))
         (mtime (and attrs (file-attribute-modification-time attrs)))
         (stamp (list mtime (and attrs (file-attribute-size attrs))
                      (and buffer (with-current-buffer buffer
                                    (buffer-chars-modified-tick)))))
         (cached (gethash file zk-dashboard--metadata-cache)))
    (if (equal stamp (car cached)) (cdr cached)
      (let* ((parse
              (lambda ()
                (save-excursion
                  (save-restriction
                    (widen)
                    (goto-char (point-min))
                    (let ((case-fold-search t) title tags)
                      (cond
                       ((or (string-match-p "\\.org\\'" file)
                            (equal file (expand-file-name zk-inbox-file)))
                        (when (re-search-forward "^#\\+title:[ \t]*\\(.*\\)$" nil t)
                          (setq title (match-string-no-properties 1)))
                        (goto-char (point-min))
                        (when (re-search-forward "^#\\+filetags:[ \t]*\\(.*\\)$" nil t)
                          (setq tags (split-string (match-string-no-properties 1) "[: \t]+" t))))
                       (t
                        (when (re-search-forward "^#[ \t]+\\(.+?\\)[ \t]*#*[ \t]*$" nil t)
                          (setq title (match-string-no-properties 1)))))
                      (list :title (zk-dashboard--plain
                                    (if (string-empty-p (or title ""))
                                        (file-name-base file) title))
                            :tags tags :file file :mtime mtime))))))
             (metadata
              (if buffer (with-current-buffer buffer (funcall parse))
                (with-temp-buffer
                  (insert-file-contents file)
                  (funcall parse)))))
        (when (and buffer (buffer-modified-p buffer))
          (setq metadata (plist-put metadata :modified t)))
        (puthash file (cons stamp metadata) zk-dashboard--metadata-cache)
        metadata))))

(defun zk-dashboard--notes ()
  "List readable notes in recent-edit order, with unsaved notes first."
  (sort (mapcar #'zk-dashboard--metadata
                (seq-filter #'file-readable-p (zk--note-files)))
        (lambda (a b)
          (cond
           ((and (plist-get a :modified) (not (plist-get b :modified))) t)
           ((and (plist-get b :modified) (not (plist-get a :modified))) nil)
           ((equal (plist-get a :mtime) (plist-get b :mtime))
            (string-lessp (plist-get a :file) (plist-get b :file)))
           (t (time-less-p (plist-get b :mtime) (plist-get a :mtime)))))))

(defun zk-dashboard--date (stamp)
  "Return the calendar day in STAMP, or nil for a missing/invalid timestamp."
  (when stamp
    (condition-case nil (org-time-string-to-absolute stamp) (error nil))))

(defun zk-dashboard--task-group (task)
  "Classify TASK's stored dates.  Org Agenda owns recurrence and reminder rules."
  (let* ((dates (delq nil (list (zk-dashboard--date (plist-get task :scheduled))
                               (zk-dashboard--date (plist-get task :deadline)))))
         (day (and dates (apply #'min dates))))
    (cond ((and day (< day (org-today))) "Overdue")
          ((and day (= day (org-today))) "Today")
          (day "Upcoming")
          ((equal (plist-get task :state) "HOLD") "Waiting")
          (t "Unscheduled"))))

(defun zk-dashboard--task-less-p (a b)
  (let ((a-day (or (plist-get a :day) most-positive-fixnum))
        (b-day (or (plist-get b :day) most-positive-fixnum)))
    (cond ((/= a-day b-day) (< a-day b-day))
          ((/= (plist-get a :priority) (plist-get b :priority))
           (> (plist-get a :priority) (plist-get b :priority)))
          ((not (equal (plist-get a :state) (plist-get b :state)))
           (string-lessp (plist-get a :state) (plist-get b :state)))
          (t (string-lessp (plist-get a :title) (plist-get b :title))))))

(defun zk--tasks ()
  "Collect open tasks from live Org buffers; skip completed and archived trees."
  (zk-refresh-agenda)
  (let (tasks)
    (dolist (file (org-agenda-files))
      (when (file-readable-p file)
        (with-current-buffer (find-file-noselect file)
          (unless (derived-mode-p 'org-mode) (org-mode))
          (org-with-wide-buffer
           (org-map-entries
            (lambda ()
              (when (and (member (org-get-todo-state) org-not-done-keywords)
                         (not (org-in-commented-heading-p))
                         (not (org-in-archived-heading-p)))
                (let* ((scheduled (org-entry-get nil "SCHEDULED"))
                       (deadline (org-entry-get nil "DEADLINE"))
                       (dates (delq nil (list (zk-dashboard--date scheduled)
                                               (zk-dashboard--date deadline))))
                       (task (list :title (zk-dashboard--plain (org-get-heading t t t t))
                                   :state (org-get-todo-state) :scheduled scheduled
                                   :deadline deadline :day (and dates (apply #'min dates))
                                   :priority (org-get-priority (thing-at-point 'line t))
                                   :source (plist-get (zk-dashboard--metadata file) :title)
                                   :file (expand-file-name file) :marker (point-marker))))
                  (push (plist-put task :group (zk-dashboard--task-group task)) tasks))))
            nil 'file)))))
    (sort tasks #'zk-dashboard--task-less-p)))

(defun zk-dashboard-task-at-point ()
  "Return the task on the current dashboard row, including its metadata line."
  (or (get-text-property (point) 'zk-task)
      (get-text-property (line-beginning-position) 'zk-task)))

(defun zk-dashboard-task-marker ()
  "Return a live task marker or ask for a refresh instead of acting on stale data."
  (let* ((task (zk-dashboard-task-at-point)) (marker (plist-get task :marker)))
    (unless task (user-error "Select a task row first"))
    (unless (and (markerp marker) (buffer-live-p (marker-buffer marker)))
      (user-error "The source buffer was closed; press g to refresh"))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (save-restriction
          (widen) (goto-char marker)
          (unless (org-at-heading-p)
            (user-error "The task moved; press g to refresh")))))
    marker))

(defun zk-dashboard-open-task ()
  (interactive)
  (let ((marker (zk-dashboard-task-marker)))
    (pop-to-buffer-same-window (marker-buffer marker))
    (widen) (goto-char marker)
    (org-fold-show-context 'agenda) (org-fold-show-entry)))

(defun zk-dashboard-item-menu ()
  (interactive)
  (zk-dashboard-task-marker)
  (zk-item-menu))

(defun zk-dashboard-open ()
  "Open the button or task on the current line."
  (interactive)
  (let ((button (or (button-at (point))
                    (let ((next (next-button (line-beginning-position) t)))
                      (and next (< (button-start next) (line-end-position)) next)))))
    (cond ((zk-dashboard-task-at-point) (zk-dashboard-open-task))
          (button (button-activate button))
          (t (user-error "Select a task, note, or action")))))

(defun zk-dashboard--width ()
  "Use the narrowest window showing this buffer, accounting for remapped fonts."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (max 20 (if windows
                (apply #'min (mapcar (lambda (w)
                                      (floor (/ (float (window-body-width w t))
                                                (max 1 (window-font-width w))))) windows))
              (window-body-width)))))

(defun zk-dashboard--fit (text width)
  (truncate-string-to-width (zk-dashboard--plain text) (max 1 width) nil nil "…"))

(defun zk-dashboard--column (column text &optional face)
  (insert (make-string (max 1 (- column (current-column))) ?\s))
  (insert (propertize text 'face (or face 'zk-dashboard-muted))))

(defun zk-dashboard--button (label action &optional help)
  (insert-text-button label 'follow-link t 'face 'zk-dashboard-action
                      'mouse-face 'highlight 'help-echo (or help label) 'action action))

(defun zk-dashboard--command (label command)
  (zk-dashboard--button label (lambda (_) (call-interactively command))))

(defun zk-dashboard--rule (width)
  (insert (propertize (make-string (max 1 width) ?─) 'face 'zk-dashboard-muted) "\n"))

(defun zk-dashboard--when (task)
  "Distinguish scheduling from a deadline, including when both are present."
  (let* ((deadline (plist-get task :deadline))
         (scheduled (plist-get task :scheduled))
         (dday (zk-dashboard--date deadline)) (sday (zk-dashboard--date scheduled))
         (due (and dday (or (not sday) (<= dday sday))))
         (stamp (if due deadline scheduled))
         (day (if due dday sday)))
    (if day
        (concat (if due "Due " "Sched. ")
                (if (= day (org-today)) "today"
                  (format-time-string "%b %d" (org-time-string-to-time stamp))))
      (if (equal (plist-get task :state) "HOLD") "Waiting" "Unscheduled"))))

(defun zk-dashboard--task-row (task width)
  (let* ((start (point)) (compact (< width 65))
         (source (>= width 110))
         (state-col (if source (- width 48) (- width 26)))
         (date-col (+ state-col 9))
         (from-col (- width 21))
         (title-width (if compact (- width 5) (- state-col 6)))
         (help (format "%s\n%s\nScheduled: %s\nDeadline: %s"
                       (plist-get task :title) (plist-get task :file)
                       (or (plist-get task :scheduled) "None")
                       (or (plist-get task :deadline) "None"))))
    (zk-dashboard--button "[ ]" (lambda (button)
                                      (goto-char (button-start button)) (zk-done))
                          "Mark this task done using Org's normal repeat rules")
    (insert " ")
    (zk-dashboard--button (zk-dashboard--fit (plist-get task :title) title-width)
                          (lambda (button)
                            (goto-char (button-start button)) (zk-dashboard-open-task)) help)
    (when compact (insert "\n    "))
    (if compact
        (insert (propertize (plist-get task :state) 'face 'org-todo) "  ")
      (zk-dashboard--column state-col (zk-dashboard--fit (plist-get task :state) 8) 'org-todo))
    (if compact
        (insert (propertize (zk-dashboard--when task) 'face 'zk-dashboard-muted))
      (zk-dashboard--column date-col (zk-dashboard--when task)
                            (if (equal (plist-get task :group) "Overdue")
                                'zk-dashboard-overdue 'zk-dashboard-muted)))
    (when source
      (zk-dashboard--column from-col "")
      (zk-dashboard--button (zk-dashboard--fit (plist-get task :source) 20)
                            (lambda (button)
                              (goto-char (button-start button)) (zk-dashboard-open-task))
                            (plist-get task :file)))
    (insert "\n")
    (add-text-properties start (point) (list 'zk-task task 'help-echo help))))

(defun zk-dashboard--tasks-section (width)
  (insert (propertize "Tasks" 'face 'zk-dashboard-heading)
          (propertize (format "  %d open" (length zk-dashboard--tasks)) 'face 'zk-dashboard-muted)
          "    ")
  (zk-dashboard--command "+ Add task [c]" #'zk-capture-task)
  (insert "\n\n")
  (if (null zk-dashboard--tasks)
      (insert (propertize "No open tasks. Press c to capture one.\n" 'face 'zk-dashboard-muted))
    (unless (< width 65)
      (let* ((state-col (- width (if (>= width 110) 48 26))))
        (insert (propertize "    TASK" 'face 'zk-dashboard-muted))
        (zk-dashboard--column state-col "STATE")
        (zk-dashboard--column (+ state-col 9) "WHEN")
        (when (>= width 110) (zk-dashboard--column (- width 21) "FROM"))
        (insert "\n")))
    (dolist (group zk-dashboard--groups)
      (let* ((tasks (seq-filter (lambda (task) (equal (plist-get task :group) group))
                                zk-dashboard--tasks))
             (expanded (member group zk-dashboard--expanded))
             (visible (if expanded tasks (seq-take tasks zk-dashboard-task-limit))))
        (when tasks
          (insert "\n" (propertize group 'face (if (equal group "Overdue")
                                                    'zk-dashboard-overdue 'bold))
                  (propertize (format "  %d" (length tasks)) 'face 'zk-dashboard-muted) "\n")
          (dolist (task visible) (zk-dashboard--task-row task width))
          (when (> (length tasks) zk-dashboard-task-limit)
            (insert "    ")
            (zk-dashboard--button
             (if expanded "Show less" (format "Show %d more" (- (length tasks) (length visible))))
             (lambda (_)
               (if (member group zk-dashboard--expanded)
                   (setq zk-dashboard--expanded (delete group zk-dashboard--expanded))
                 (push group zk-dashboard--expanded))
               (zk-dashboard--render)))
            (insert "\n"))))))
  (insert "\n")
  (zk-dashboard--command "View agenda [t]" #'zk-today)
  (insert "    ") (zk-dashboard--command "Inbox [i]" #'zk-inbox)
  (insert "\n" (propertize "RET Open task    x Task actions" 'face 'zk-dashboard-muted))
  (insert "\n"))

(defun zk-dashboard--updated (note)
  (if (plist-get note :modified) "Unsaved"
    (let ((days (- (org-today) (time-to-days (plist-get note :mtime)))))
      (cond ((= days 0) "Today") ((= days 1) "Yesterday")
            (t (format-time-string "%b %d" (plist-get note :mtime)))))))

(defun zk-dashboard--notes-section (width)
  (insert (propertize "Notes" 'face 'zk-dashboard-heading)
          (propertize (format "  %d" (length zk-dashboard--notes)) 'face 'zk-dashboard-muted) "    ")
  (zk-dashboard--command "+ New note [n]" #'zk-new-note)
  (insert "\n" (propertize "Recently edited" 'face 'zk-dashboard-muted) "\n\n")
  (let* ((dates (>= width 55)) (tags (>= width 90))
         (date-col (- width 10)) (tags-col (- width 34))
         (title-width (if tags (- tags-col 2) (if dates (- date-col 2) width))))
    (if (null zk-dashboard--notes)
        (insert (propertize "No notes yet. Press n to start writing.\n" 'face 'zk-dashboard-muted))
      (insert (propertize "TITLE" 'face 'zk-dashboard-muted))
      (when tags (zk-dashboard--column tags-col "TAGS"))
      (when dates (zk-dashboard--column date-col "UPDATED"))
      (insert "\n")
      (dolist (note (seq-take zk-dashboard--notes zk-dashboard-note-limit))
        (let ((start (point)) (file (plist-get note :file)))
          (zk-dashboard--button (zk-dashboard--fit (plist-get note :title) title-width)
                                (lambda (_) (find-file file)) file)
          (when tags (zk-dashboard--column tags-col
                                           (zk-dashboard--fit (string-join (plist-get note :tags) ", ") 22)))
          (when dates (zk-dashboard--column date-col (zk-dashboard--updated note)))
          (insert "\n")
          (add-text-properties start (point) (list 'zk-note-file file))))))
  (insert "\n") (zk-dashboard--command "Browse all notes [f]" #'zk-find-note)
  (insert "    ") (zk-dashboard--command "Search [s]" #'zk-search)
  (insert "\n"))

(defun zk-dashboard--render ()
  "Render cached data while preserving the current row and scroll position."
  (let* ((inhibit-read-only t)
         (system-time-locale "C")
         (width (zk-dashboard--width))
         (old-point (point))
         (old-task (zk-dashboard-task-at-point))
         (old-marker (plist-get old-task :marker))
         (old-note (get-text-property (point) 'zk-note-file))
         (windows (mapcar (lambda (w) (cons w (window-start w)))
                          (get-buffer-window-list (current-buffer) nil t))))
    (setq zk-dashboard--width width)
    (erase-buffer)
    (insert (propertize (format-time-string "%A, %B %d, %Y") 'face 'zk-dashboard-muted) "\n\n")
    (zk-dashboard--tasks-section width)
    (insert "\n") (zk-dashboard--rule width) (insert "\n")
    (zk-dashboard--notes-section width)
    (goto-char (point-min))
    (let ((found nil))
      (while (and (not found) (< (point) (point-max)))
        (when (or (and old-marker
                       (equal old-marker (plist-get (zk-dashboard-task-at-point) :marker)))
                  (and old-note (equal old-note (get-text-property (point) 'zk-note-file))))
          (setq found (point)))
        (forward-line 1))
      (goto-char (or found (min old-point (point-max)))))
    (dolist (entry windows)
      (when (window-live-p (car entry))
        (set-window-start (car entry) (min (cdr entry) (point-max)) t)))
    (set-buffer-modified-p nil)))

(defun zk-dashboard-refresh ()
  "Refresh an existing dashboard without changing the selected window."
  (interactive)
  (when (timerp zk-dashboard--refresh-timer) (cancel-timer zk-dashboard--refresh-timer))
  (setq zk-dashboard--refresh-timer nil)
  (when-let* ((buffer (get-buffer zk-dashboard-buffer-name)))
    (with-current-buffer buffer
      (setq zk-dashboard--tasks (zk--tasks)
            zk-dashboard--notes (zk-dashboard--notes))
      (zk-dashboard--render))))

(defun zk-dashboard-request-refresh (&rest _)
  "Coalesce source edits into one idle refresh, without opening a dashboard."
  (when (get-buffer zk-dashboard-buffer-name)
    (when (timerp zk-dashboard--refresh-timer) (cancel-timer zk-dashboard--refresh-timer))
    (setq zk-dashboard--refresh-timer
          (run-with-idle-timer
           0.2 nil (lambda ()
                     (setq zk-dashboard--refresh-timer nil)
                     (when (get-buffer-window zk-dashboard-buffer-name t)
                       (zk-dashboard-refresh)))))))

(defun zk-dashboard--source-changed ()
  (when (and buffer-file-name
             (or (file-in-directory-p buffer-file-name zk-root)
                 (member buffer-file-name (org-agenda-files))))
    (remhash (expand-file-name buffer-file-name) zk-dashboard--metadata-cache)
    (zk-dashboard-request-refresh)))

(defun zk-dashboard--window-changed (window)
  (when (and (window-live-p window)
             (eq (window-buffer window) (current-buffer)))
    (zk-dashboard-request-refresh)))

(defun zk-dashboard--resized (_frame)
  (when-let* ((buffer (get-buffer zk-dashboard-buffer-name)))
    (when (get-buffer-window buffer t)
      (with-current-buffer buffer
        (unless (equal zk-dashboard--width (zk-dashboard--width))
          (zk-dashboard--render))))))

(defvar zk-home-mode-map (make-sparse-keymap))
;; Update existing maps too, so reloading a previous zk version is sufficient.
(set-keymap-parent zk-home-mode-map special-mode-map)
(dolist (entry '(("TAB" . forward-button) ("<backtab>" . backward-button)
                     ("RET" . zk-dashboard-open) ("g" . zk-dashboard-refresh)
                     ("c" . zk-capture-task) ("n" . zk-new-note)
                     ("t" . zk-today) ("i" . zk-inbox) ("d" . zk-daily)
                     ("w" . zk-week) ("p" . zk-weekly) ("f" . zk-find-note)
                     ("s" . zk-search) ("x" . zk-dashboard-item-menu) ("?" . zk-menu)))
  (define-key zk-home-mode-map (kbd (car entry)) (cdr entry)))

(define-derived-mode zk-home-mode special-mode "ZK Dashboard"
  "Read tasks and notes, with direct capture and navigation actions."
  (setq-local truncate-lines t line-spacing 0.12
              left-margin-width 2 right-margin-width 2
              header-line-format
              '((:propertize "  ZK" face bold)
                "    c Add task    n New note    s Search    ? Commands")
              mode-line-format
              '("  ZK  " (:eval (format "%d open tasks / %d notes"
                                        (length zk-dashboard--tasks) (length zk-dashboard--notes)))
                "    RET Open    x Actions    g Refresh"))
  (face-remap-add-relative 'default :inherit 'fixed-pitch :height zk-dashboard-text-height)
  (face-remap-add-relative 'header-line :height zk-dashboard-text-height)
  (hl-line-mode 1)
  (add-hook 'window-buffer-change-functions #'zk-dashboard--window-changed nil t))

(defun zk-home ()
  "Open the compact English dashboard."
  (interactive)
  (let ((buffer (get-buffer-create zk-dashboard-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'zk-home-mode) (zk-home-mode)))
    (pop-to-buffer-same-window buffer)
    (zk-dashboard-refresh)
    buffer))

(add-hook 'after-save-hook #'zk-dashboard--source-changed)
(add-hook 'after-revert-hook #'zk-dashboard--source-changed)
(add-hook 'org-after-todo-state-change-hook #'zk-dashboard-request-refresh)
(add-hook 'org-after-refile-insert-hook #'zk-dashboard-request-refresh)
(add-hook 'window-size-change-functions #'zk-dashboard--resized)

(provide 'zk-dashboard)
;;; zk-dashboard.el ends here
