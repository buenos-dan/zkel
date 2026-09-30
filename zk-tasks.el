;;; zk-tasks.el --- Agenda projects and task operations -*- lexical-binding: t; -*-

;;; Commentary:
;; Agenda projects and task operations

;;; Code:
(require 'zk-org-store)

(defun zk-projects ()
  "Areas and project destinations. Existing outline containers remain usable."
  (zk-org-query (zk-agenda-path)
                (lambda ()
                  (and (not (zk-org-state))
                       (not (org-entry-get nil "SCHEDULED"))
                       (not (org-entry-get nil "DEADLINE"))
                       (not (member (or (car (org-get-outline-path)) (zk-org-title))
                                    '("Reviews" "Weekly reviews" "Archive" "Brithdays" "Birthdays")))
                       (or (= (org-outline-level) 1)
                           (equal (org-entry-get nil "ZK_TYPE") "project")
                           (save-excursion
                             (let ((end (zk-org-subtree-end)))
                               (forward-line 1)
                               (re-search-forward org-heading-regexp end t))))))))

(defun zk-project-create (title area)
  "Create a project below an existing AREA snapshot, or a new top-level name."
  (setq title (zk-library-validate-title title))
  (let ((parent (and (listp area) (zk-org-resolve area))))
    (when (stringp area) (zk-library-validate-title area))
    (unless (or parent (stringp area)) (user-error "Choose an area"))
    (when
        (and parent
             (not
              (zk-library-same-file-p (buffer-file-name (marker-buffer parent)) (zk-agenda-path))))
      (user-error "Project destination must be in the agenda"))
    (zk-org-transaction
     (list (zk-agenda-path))
     (lambda ()
       (with-current-buffer (zk-org-buffer (zk-agenda-path))
         (org-with-wide-buffer
          (zk-org-append-child (or parent (zk-org-ensure-container area)) title nil "project")
          (zk-org-entry)))))))

(defun zk-tasks (&optional state)
  "Agenda actions with project and area context. Inbox is never a task list."
  (let ((tasks (zk-org-query (zk-agenda-path)
                             (lambda () (let ((s (zk-org-state)))
                                          (and s (not (member s (zk-org-states 'done)))
                                               (or (null state) (equal state s))))))))
    (sort tasks (lambda (a b)
                  (if (/= (plist-get a :priority) (plist-get b :priority))
                      (> (plist-get a :priority) (plist-get b :priority))
                    (string-lessp (string-join (plist-get a :path) "/")
                                  (string-join (plist-get b :path) "/")))))))

(defun zk-task-update (reference &rest properties)
  "Update a task using its snapshot revision.
Fields are :state, :scheduled and :deadline.
An empty date removes it. Unspecified fields and repeaters are preserved."
  (let ((state (plist-get properties :state)) (scheduled (plist-get properties :scheduled))
        (deadline (plist-get properties :deadline)) (marker (zk-org-resolve reference)))
    (dolist (key (cl-loop for (k _v) on properties by #'cddr collect k))
      (unless (memq key '(:state :scheduled :deadline)) (user-error "Unknown task field: %s" key)))
    (when (and state (not (member state (zk-org-states)))) (user-error "Unknown task state"))
    (zk-org-validate-date scheduled) (zk-org-validate-date deadline)
    (unless (zk-library-same-file-p (buffer-file-name (marker-buffer marker)) (zk-agenda-path))
      (user-error "Process the inbox entry before changing task state"))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (unless (zk-org-state) (user-error "This entry is not a task"))))
    (zk-org-transaction
     (list (zk-agenda-path))
     (lambda ()
       (with-current-buffer (marker-buffer marker)
         (org-with-wide-buffer
          (goto-char marker) (zk-org-ensure-id)
          (when state (zk-org-set-state state))
          (zk-org-set-dates scheduled deadline)
          (zk-org-entry)))))))

(defun zk-task-display-state (entry)
  "Return ENTRY's state, or DONE for a logged completion of a repeating task."
  (or (plist-get entry :display-state) (plist-get entry :state)))

(defun zk-tasks--today-p (stamp)
  (and stamp
       (condition-case nil (= (org-time-string-to-absolute stamp) (org-today))
         (error nil))))

(defun zk-tasks--repeat-completion ()
  "Read today's last repeat completion from Org's own metadata and log."
  (let ((stamp (org-entry-get nil "LAST_REPEAT")))
    (when (and (zk-tasks--today-p stamp) (org-get-repeat))
      (save-excursion
        (let ((end (org-entry-end-position)))
          (when (re-search-forward
                 (concat "^[ \t]*- State +\"DONE\".*" (regexp-quote stamp)) end t)
            stamp))))))

(defun zk-tasks--collect ()
  "Read task records and their real ancestor headings, in source order."
  (when (file-readable-p (zk-agenda-path))
    (with-current-buffer (zk-org-buffer (zk-agenda-path))
      (org-with-wide-buffer
       (let (stack roots records)
         (org-map-entries
          (lambda ()
            (unless (or (org-in-archived-heading-p) (org-in-commented-heading-p))
              (let* ((level (org-outline-level)) (state (zk-org-state))
                     (entry (append (zk-org-entry) (list :source-marker (copy-marker (point) t))))
                     (node (list :entry entry :children nil :todo 0 :next 0 :level level)))
                (while (and stack (>= (plist-get (car stack) :level) level)) (pop stack))
                (if stack
                    (push node (plist-get (car stack) :children))
                  (push node roots))
                (when state
                  (when-let* ((stamp (and (equal state "TODO") (zk-tasks--repeat-completion))))
                    (setq entry (plist-put entry :completed-at stamp))
                    (setq entry (plist-put entry :display-state "DONE")))
                  (when (and (equal state "DONE") (zk-tasks--today-p (plist-get entry :closed)))
                    (setq entry (plist-put entry :completed-at (plist-get entry :closed))))
                  (setq entry (plist-put entry :ancestor-keys
                                         (mapcar (lambda (parent) (zk-task-tree-key parent)) (reverse stack))))
                  (setf (plist-get node :entry) entry)
                  (push entry records)
                  (when (member state '("TODO" "NEXT"))
                    (dolist (parent (cons node stack))
                      (let ((key (if (equal state "TODO") :todo :next)))
                        (setf (plist-get parent key) (1+ (plist-get parent key)))))))
                (push node stack))))
          nil 'file)
         (list :records (nreverse records) :roots (nreverse roots)))))))

(defun zk-task-tree-key (node)
  "Return a stable session identity for NODE without assigning IDs on reads."
  (let ((entry (plist-get node :entry)))
    (or (plist-get entry :id) (plist-get entry :source-marker))))

(defun zk-tasks--prune-tree (nodes)
  (delq nil
        (mapcar
         (lambda (node)
           (when (> (+ (plist-get node :todo) (plist-get node :next)) 0)
             (setf (plist-get node :children) (zk-tasks--prune-tree (nreverse (plist-get node :children))))
             node))
         nodes)))

(defun zk-tasks-overview ()
  "Return :daily (NEXT then today's DONE) and :projects in source outline order.
Completion dates come from CLOSED, or from today's LAST_REPEAT and DONE log.
A repeating task currently set to NEXT appears only as NEXT, never twice."
  (let* ((all (zk-tasks--collect)) next done)
    (dolist (entry (plist-get all :records))
      (cond ((equal (plist-get entry :state) "NEXT") (push entry next))
            ((plist-get entry :completed-at) (push entry done))))
    (list :daily
          (append
           (sort next (lambda (a b)
                        (if (= (plist-get a :priority) (plist-get b :priority))
                            (< (plist-get a :position) (plist-get b :position))
                          (> (plist-get a :priority) (plist-get b :priority)))))
           (sort done (lambda (a b)
                        (time-less-p (org-time-string-to-time (plist-get b :completed-at))
                                     (org-time-string-to-time (plist-get a :completed-at))))))
          :projects (zk-tasks--prune-tree (plist-get all :roots)))))

(provide 'zk-tasks)
;;; zk-tasks.el ends here
