;;; zk-commands.el --- User commands and transient menus -*- lexical-binding: t; -*-

;;; Commentary:
;; User commands and transient menus

;;; Code:
(require 'zk-ui)
(require 'zk-inbox)
(require 'zk-agenda)
(require 'transient)

(autoload 'zk-home "zk-home" nil t)
(autoload 'zk-home-agenda-day "zk-home" nil t)
(autoload 'zk-home-agenda-week "zk-home" nil t)

(autoload 'zk-inbox-review-open "zk-inbox-review")

;;;###autoload
(defun zk-open-agenda () (interactive) (find-file (zk-agenda-path)))

;;;###autoload
(defun zk-create-project (title area)
  (interactive (list (read-string "Project outcome: ")
                     (completing-read "Area: " (mapcar (lambda (p) (plist-get p :title))
                                                       (seq-filter
                                                        (lambda (p)
                                                          (= 1 (length (plist-get p :path))))
                                                        (zk-projects)))
                                      nil nil)))
  (let ((project (zk-project-create title area))) (zk-ui-open project)))

;;;###autoload
(defun zk-process-inbox ()
  "Open the unified Inbox workspace, starting at a source item or New."
  (interactive)
  (let* ((entries (zk-inbox-entries)) (current (zk-ui-current-entry))
         (selected
          (when (and (derived-mode-p 'org-mode) current
                     (zk-library-same-file-p (plist-get current :file) (zk-inbox-path)))
            (or (seq-find (lambda (entry)
                            (and (plist-get current :id)
                                 (equal (plist-get current :id) (plist-get entry :id))))
                          entries)
                (when (derived-mode-p 'org-mode)
                  (seq-find (lambda (entry)
                              (let ((marker (zk-org-locate entry)) (position (point)))
                                (save-excursion
                                  (goto-char marker)
                                  (and (>= position (point)) (< position (zk-org-subtree-end))))))
                            entries))))))
    (zk-inbox-review-open selected)))

;;;###autoload
(defun zk-task-set-state (state)
  (interactive (list (completing-read "State: " (zk-org-states) nil t)))
  (zk-ui-report
   (zk-task-update (or (zk-ui-current-entry) (zk-ui-choose "Task: " (zk-tasks))) :state state)))

;;;###autoload
(defun zk-done () (interactive) (zk-task-set-state "DONE"))

;;;###autoload
(defun zk-next () (interactive) (zk-task-set-state "NEXT"))

;;;###autoload
(defun zk-reset () (interactive) (zk-task-set-state "TODO"))

;;;###autoload
(defun zk-schedule ()
  (interactive)
  (let ((entry (or (zk-ui-current-entry) (zk-ui-choose "Task: " (zk-tasks)))))
    (zk-ui-report (zk-task-update entry :scheduled (read-string "Schedule (empty removes): ")))))

;;;###autoload
(defun zk-deadline ()
  (interactive)
  (let ((entry (or (zk-ui-current-entry) (zk-ui-choose "Task: " (zk-tasks)))))
    (zk-ui-report (zk-task-update entry :deadline (read-string "Deadline (empty removes): ")))))

;;;###autoload
(defun zk-new-note (filename)
  "Create a note using FILENAME, including its .org or .md extension."
  (interactive (list (zk-ui-read-new-note-filename)))
  (zk-ui-open (zk-note-create filename))
  (goto-char (point-max)))

;;;###autoload
(defun zk-find-note ()
  "Open an Org or Markdown note by filename, not its internal heading."
  (interactive)
  (find-file (zk-ui-read-note-file)))

;;;###autoload
(defun zk-search ()
  (interactive)
  (if (and (fboundp 'consult-ripgrep) (executable-find "rg")) (consult-ripgrep zk-root)
    (require 'grep) (rgrep (read-string "Search: ") "*.org *.md" zk-root)))

;;;###autoload
(defun zk-insert-link ()
  "Insert an ID link, using a file link for older notes that have no ID yet."
  (interactive)
  (let* ((note (zk-ui-choose "Link to note: " (zk-notes)))
         (id (plist-get note :id)))
    (insert (org-link-make-string (if id (concat "id:" id)
                                    (concat "file:"
                                            (file-relative-name (plist-get note :file)
                                                                default-directory)))
                                  (plist-get note :title)))))

;;;###autoload
(defun zk-show-backlinks ()
  (interactive)
  (let* ((entry (or (zk-ui-current-entry) (zk-ui-choose "Note: " (zk-notes))))
         (links (zk-backlinks entry)))
    (zk-ui-open (zk-ui-choose "Referenced in: "
                              (mapcar (lambda (link) (plist-put link :title (format "%s:%d %s"
                                                                                    (file-name-nondirectory
                                                                                     (plist-get
                                                                                      link :file))
                                                                                    (plist-get link
                                                                                               :line)
                                                                                    (plist-get link
                                                                                               :text))))
                                      links)))))

;;;###autoload
(defun zk-today () (interactive) (zk-home-agenda-day))

;;;###autoload
(defun zk-week () (interactive) (zk-home-agenda-week))

;;;###autoload
(defun zk-year ()
  "Open the current calendar year in a standalone Org Agenda buffer."
  (interactive) (zk-agenda-view 'year))

;;;###autoload (autoload 'zk-item-menu "zk-commands" nil t)
(transient-define-prefix zk-item-menu ()
                         "Actions on the selected agenda task."
                         [["Status" ("t" "TODO" zk-reset) ("n" "NEXT" zk-next) ("d" "DONE" zk-done)]
                          ["Dates" ("s" "Schedule" zk-schedule) ("e" "Deadline" zk-deadline)]])

;;;###autoload (autoload 'zk-menu "zk-commands" nil t)
(transient-define-prefix zk-menu ()
                         "Collect, clarify, act, and connect knowledge."
                         [["Collect and clarify" ("i" "Inbox" zk-process-inbox)
                           ("p" "Create project" zk-create-project)]
                          ["Act"
                           ("a" "Open agenda" zk-open-agenda)
                           ("d" "Day" zk-today) ("w" "Week" zk-week) ("y" "Year" zk-year)
                           ("x" "Task actions" zk-item-menu)]
                          ["Knowledge" ("n" "New note" zk-new-note) ("f" "Find note" zk-find-note)
                           ("s" "Search" zk-search) ("l" "Insert link" zk-insert-link)
                           ("b" "Backlinks" zk-show-backlinks)
                           ("h" "ZK" zk-home)]])

(provide 'zk-commands)
;;; zk-commands.el ends here
