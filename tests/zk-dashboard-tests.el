;;; zk-dashboard-tests.el --- Behavioral tests for zk -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(unless noninteractive (error "Run this test suite in a separate batch Emacs"))
(defvar zk-test-bootstrap-directory (make-temp-file "zk-tests-bootstrap-" t))
(defvar zk-root)
(defvar zk-inbox-file)
(defvar zk-state-directory)
(defvar org-agenda-files)
(setq zk-root (expand-file-name "notes/" zk-test-bootstrap-directory)
      zk-inbox-file (expand-file-name "inbox.org" zk-test-bootstrap-directory)
      zk-state-directory (expand-file-name "state/" zk-test-bootstrap-directory)
      org-agenda-files nil)
(add-hook 'kill-emacs-hook (lambda () (delete-directory zk-test-bootstrap-directory t)))
(require 'zk)

(defmacro zk-test-with-library (&rest body)
  `(let* ((root (make-temp-file "zk-test-" t))
          (zk-root (file-name-as-directory root))
          (zk-inbox-file (expand-file-name "inbox.org" root))
          (zk-state-directory (expand-file-name "state/" root))
          (zk--previous-agenda-files nil)
          (org-agenda-files nil)
          (zk-dashboard--metadata-cache (make-hash-table :test #'equal))
          (org-id-locations-file (expand-file-name "ids" root))
          (org-capture-templates nil)
          (org-agenda-sticky nil))
     (unwind-protect
         (progn
           (when-let* ((old (get-buffer zk-dashboard-buffer-name))) (kill-buffer old))
           (make-directory (expand-file-name "org-notes" root) t)
           (make-directory (expand-file-name "backups" zk-state-directory) t)
           ,@body)
       (when (timerp zk-dashboard--refresh-timer) (cancel-timer zk-dashboard--refresh-timer))
       (setq zk-dashboard--refresh-timer nil)
       (dolist (buffer (buffer-list))
         (with-current-buffer buffer
           (when (or (equal (buffer-name) zk-dashboard-buffer-name)
                     (and buffer-file-name (file-in-directory-p buffer-file-name root))
                     (derived-mode-p 'org-agenda-mode))
             (set-buffer-modified-p nil) (kill-buffer buffer))))
       (delete-directory root t))))

(defun zk-test-write (name text)
  (let ((file (expand-file-name name zk-root)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))
    file))

(defun zk-test-date (offset &optional repeater)
  (pcase-let ((`(,month ,day ,year) (calendar-gregorian-from-absolute (+ (org-today) offset))))
    (concat (format-time-string "<%Y-%m-%d %a" (encode-time 0 0 12 day month year))
            (or repeater "") ">")))

(defun zk-test-select-task (title)
  (goto-char (point-min))
  (while (and (< (point) (point-max))
              (not (equal title (plist-get (zk-dashboard-task-at-point) :title))))
    (forward-line 1))
  (unless (zk-dashboard-task-at-point) (error "Task not found: %s" title)))

(ert-deftest zk-dashboard-classifies-every-open-task ()
  (zk-test-with-library
   (zk-test-write "org-notes/ordinary.org"
                  (format "#+title: Project\n* TODO Past\nDEADLINE: %s\n* NEXT Today\nSCHEDULED: %s\n* TODO Future\nSCHEDULED: %s\n* TODO Inbox\n* HOLD Waiting\n* DONE Finished\n* CANCELLED Cancelled\n* COMMENT Hidden\n** TODO Comment child\n* Archive :ARCHIVE:\n** TODO Archived child\n"
                          (zk-test-date -1) (zk-test-date 0) (zk-test-date 2)))
   (let ((tasks (zk--tasks)))
     (should (= 5 (length tasks)))
     (dolist (entry '(("Past" . "Overdue") ("Today" . "Today") ("Future" . "Upcoming")
                      ("Inbox" . "Unscheduled") ("Waiting" . "Waiting")))
       (should (equal (cdr entry)
                      (plist-get (seq-find (lambda (task) (equal (car entry) (plist-get task :title))) tasks) :group))))
     (should (member (expand-file-name "org-notes/ordinary.org" zk-root) (org-agenda-files))))))

(ert-deftest zk-dashboard-deadline-and-schedule-are-distinct ()
  (should (equal "Today" (zk-dashboard--task-group
                          (list :scheduled (zk-test-date 3) :deadline (zk-test-date 0)))))
  (should (equal "Due today" (zk-dashboard--when
                             (list :scheduled (zk-test-date 3) :deadline (zk-test-date 0)))))
  (should (equal "Sched. today" (zk-dashboard--when (list :scheduled (zk-test-date 0)))))
  (should (equal "Unscheduled" (zk-dashboard--task-group (list :state "TODO" :deadline "invalid")))))

(ert-deftest zk-dashboard-sorts-by-date-then-priority ()
  (zk-test-with-library
   (zk-test-write "org-notes/sort.org"
                  (format "* TODO [#C] Later\nDEADLINE: %s\n* TODO [#C] Low\nDEADLINE: %s\n* TODO [#A] High\nDEADLINE: %s\n"
                          (zk-test-date 1) (zk-test-date 0) (zk-test-date 0)))
   (should (equal '("High" "Low" "Later") (mapcar (lambda (task) (plist-get task :title)) (zk--tasks))))))

(ert-deftest zk-dashboard-live-edits-are-not-saved-by-reading ()
  (zk-test-with-library
   (let ((file (zk-test-write "org-notes/live.org" "#+title: Original\n#+filetags: :one:two:\n* TODO Original task\n")))
     (should (equal "Original" (plist-get (zk-dashboard--metadata file) :title)))
     (with-current-buffer (find-file-noselect file)
       (goto-char (point-min)) (search-forward "Original") (replace-match "Edited")
       (goto-char (point-max)) (insert "* NEXT Unsaved task\n")
       (should (equal "Edited" (plist-get (zk-dashboard--metadata file) :title)))
       (should (= 2 (length (zk--tasks))))
       (should (buffer-modified-p)))
     (with-temp-buffer (insert-file-contents file) (should (search-forward "Original" nil t))))))

(ert-deftest zk-dashboard-startup-returns-a-live-buffer ()
  (zk-test-with-library
   (should (buffer-live-p (zk-home)))
   (should (eq major-mode 'zk-home-mode))
   (should (string-match-p "No open tasks" (buffer-string)))
   (should (string-match-p "No notes yet" (buffer-string)))
   (should (eq (key-binding (kbd "c")) 'zk-capture-task))
   (should (eq (key-binding (kbd "n")) 'zk-new-note))))

(ert-deftest zk-dashboard-capture-refreshes-without-leaving-home ()
  (zk-test-with-library
   (zk-home)
   (let ((home (current-buffer)))
     (zk-capture-task "Captured from dashboard")
     (should (eq home (current-buffer)))
     (should (string-match-p "Captured from dashboard" (buffer-string)))
     (should (string-match-p "Unscheduled" (buffer-string)))
     (should (= 1 (length zk-dashboard--tasks))))))

(ert-deftest zk-dashboard-new-note-refreshes-and-opens-editor ()
  (zk-test-with-library
   (zk-home)
   (zk-new-note "A new idea")
   (should (derived-mode-p 'org-mode))
   (should (file-exists-p buffer-file-name))
   (with-current-buffer zk-dashboard-buffer-name
     (should (string-match-p "A new idea" (buffer-string)))
     (should (= 1 (length zk-dashboard--notes))))))

(ert-deftest zk-dashboard-completion-preserves-dashboard-and-repeat-rules ()
  (zk-test-with-library
   (zk-test-write "org-notes/tasks.org"
                  (format "* TODO One-off\n* TODO Repeat\nSCHEDULED: %s\n" (zk-test-date 0 " +1w")))
   (zk-home)
   (let ((home (current-buffer)))
     (zk-test-select-task "One-off") (zk-done)
     (should (eq home (current-buffer)))
     (should (= 1 (length zk-dashboard--tasks)))
     (zk-test-select-task "Repeat") (zk-done)
     (should (eq home (current-buffer)))
     (should (= 1 (length zk-dashboard--tasks)))
     (should (equal "Upcoming" (plist-get (car zk-dashboard--tasks) :group))))))

(ert-deftest zk-dashboard-closing-source-buffer-is-safe ()
  (zk-test-with-library
   (zk-test-write "org-notes/tasks.org" "* TODO Test task\n")
   (zk-home)
   (zk-test-select-task "Test task")
   (kill-buffer (marker-buffer (plist-get (zk-dashboard-task-at-point) :marker)))
   (should-error (zk-done) :type 'user-error)
   (zk-dashboard-refresh)
   (zk-test-select-task "Test task")
   (should (markerp (zk-dashboard-task-marker)))))

(ert-deftest zk-dashboard-task-actions-do-not-save-earlier-edits ()
  (zk-test-with-library
   (let ((file (zk-test-write "org-notes/tasks.org" "* TODO Task\nOriginal text\n")))
     (with-current-buffer (find-file-noselect file)
       (goto-char (point-max)) (insert "Unfinished draft\n"))
     (zk-home)
     (zk-test-select-task "Task")
     (zk-next)
     (should (equal "NEXT" (plist-get (car zk-dashboard--tasks) :state)))
     (with-current-buffer (get-file-buffer file) (should (buffer-modified-p)))
     (with-temp-buffer
       (insert-file-contents file)
       (should (search-forward "TODO Task" nil t))
       (should-not (search-forward "Unfinished draft" nil t))))))

(ert-deftest zk-dashboard-narrow-rows-keep-dates-and-wide-text ()
  (zk-test-with-library
   (zk-test-write "org-notes/notes.org"
                  (format "#+title: 知识整理与卡片笔记\n#+filetags: :zettelkasten:notes:\n* NEXT 一个足够长的中文待办事项与英语 mixed text\nDEADLINE: %s\n" (zk-test-date 0)))
   (zk-home)
   (dolist (width '(48 80 120))
     (cl-letf (((symbol-function 'zk-dashboard--width) (lambda () width)))
       (zk-dashboard--render)
       (should (string-match-p "Due today" (buffer-string)))
       (goto-char (point-min))
       (while (< (point) (point-max))
         (should (<= (string-width (buffer-substring (line-beginning-position) (line-end-position))) width))
         (forward-line 1))))))

(ert-deftest zk-dashboard-expansion-preserves-hidden-task-access ()
  (zk-test-with-library
   (zk-test-write "org-notes/tasks.org" "* TODO A\n* TODO B\n* TODO C\n* TODO D\n")
   (let ((zk-dashboard-task-limit 2))
     (zk-home)
     (should (= 4 (length zk-dashboard--tasks)))
     (goto-char (point-min)) (search-forward "Show 2 more")
     (button-activate (button-at (1- (point))))
     (should (member "Unscheduled" zk-dashboard--expanded))
     (should (string-match-p "Show less" (buffer-string))))))

(ert-deftest zk-dashboard-agenda-still-uses-org ()
  (zk-test-with-library
   (zk-test-write "org-notes/calendar.org"
                  (format "* TODO Agenda task\nSCHEDULED: %s\n" (zk-test-date 0)))
   (zk-today)
   (should (derived-mode-p 'org-agenda-mode))
   (should (string-match-p "Agenda task" (buffer-string)))))

(provide 'zk-dashboard-tests)
;;; zk-dashboard-tests.el ends here
