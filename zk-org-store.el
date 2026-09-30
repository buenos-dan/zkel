;;; zk-org-store.el --- Org records, identity, edits and transactions -*- lexical-binding: t; -*-

;;; Commentary:
;; Org records, identity, edits and transactions

;;; Code:
(require 'zk-org)
(require 'org)
(require 'org-id)
(require 'org-element)

(defvar zk-org-transaction-active nil)

(defun zk-org-buffer (file)
  "Visit FILE without changing the selected window."
  (let ((buffer (find-file-noselect file)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'org-mode) (org-mode)))
    buffer))

(defun zk-org-state ()
  "Read a task keyword even when the user's global Org keywords differ."
  (save-excursion
    (org-back-to-heading t)
    (when (looking-at (concat "^\\*+ +\\(" (regexp-opt (zk-org-states)) "\\)\\(?: +\\|$\\)"))
      (match-string-no-properties 1))))

(defun zk-org-title ()
  (replace-regexp-in-string
   (concat "\\`\\(?:" (regexp-opt (zk-org-states)) "\\) +") ""
   (org-get-heading t t t t)))

(defun zk-org-subtree-end () (save-excursion (org-end-of-subtree t t) (point)))

(defun zk-org-store--revision ()
  (secure-hash 'sha256
               (buffer-substring-no-properties (line-beginning-position) (zk-org-subtree-end))))

(defun zk-org-ensure-id ()
  (or (org-entry-get nil "ID")
      (let ((id (org-id-new))) (org-entry-put nil "ID" id) id)))

(defun zk-org-store--collected-at ()
  "Read a stored capture date without guessing from file modification time."
  (or (org-entry-get nil "CREATED")
      (save-excursion
        (let ((end (org-entry-end-position)))
          (when (re-search-forward "^Captured:[ \t]*\\(\\[[^]\n]+\\]\\)" end t)
            (match-string-no-properties 1))))))

(defun zk-org-entry ()
  "Snapshot the heading at point. Reading never assigns an ID."
  (if (org-before-first-heading-p)
      (list :record 'entry :scope 'file :id (org-entry-get (point-min) "ID") :file buffer-file-name
            :position (point-min)
            :revision (secure-hash 'sha256 (buffer-substring-no-properties (point-min) (point-max)))
            :title (file-name-base buffer-file-name) :type "note")
    (org-back-to-heading t)
    (list :record 'entry :scope 'heading :id (org-entry-get nil "ID") :file buffer-file-name
          :position (point)
          :revision (zk-org-store--revision) :title (zk-org-title) :state (zk-org-state)
          :type (org-entry-get nil "ZK_TYPE")
          :created (zk-org-store--collected-at) :origin (org-entry-get nil "ZK_ORIGIN")
          :closed (org-entry-get nil "CLOSED")
          :scheduled (org-entry-get nil "SCHEDULED") :deadline (org-entry-get nil "DEADLINE")
          :priority (org-get-priority (thing-at-point 'line t))
          :category (org-get-category) :path (append (org-get-outline-path) (list (zk-org-title)))
          :tags (org-get-tags))))

(defun zk-org-locate (reference)
  "Locate REFERENCE by identity without rejecting an older snapshot.
Navigation uses this function; writes use `zk-org-resolve'."
  (let* ((id (if (stringp reference) reference (plist-get reference :id)))
         (file (and (listp reference) (plist-get reference :file))) marker)
    (when id
      (dolist (candidate (delete-dups (append (and file (list file)) (zk-files t))))
        (when (and (not marker) (file-readable-p candidate))
          (with-current-buffer (zk-org-buffer candidate)
            (org-with-wide-buffer
             (goto-char (point-min))
             (when
                 (re-search-forward (concat "^[ \t]*:ID:[ \t]+" (regexp-quote id) "[ \t]*$") nil t)
               (if (org-before-first-heading-p) (goto-char (point-min)) (org-back-to-heading t))
               (setq marker (point-marker))))))))
    (unless marker
      (when (and (not id) file (zk-library-file-p file) (integerp (plist-get reference :position)))
        (with-current-buffer (zk-org-buffer file)
          (org-with-wide-buffer
           (let ((source (plist-get reference :source-marker)))
             (goto-char (min (point-max)
                             (max (point-min)
                                  (if (and (markerp source) (eq (marker-buffer source) (current-buffer)))
                                      (marker-position source)
                                    (plist-get reference :position))))))
           (when (or (org-at-heading-p) (eq (plist-get reference :scope) 'file))
             (setq marker (point-marker)))))))
    (unless marker (user-error "Entry not found; refresh the list"))
    (when (eq (plist-get (and (listp reference) reference) :scope) 'file)
      (with-current-buffer (marker-buffer marker)
        (save-restriction (widen) (set-marker marker (point-min)))))
    marker))

(defun zk-org-resolve (reference)
  "Locate REFERENCE and reject a changed snapshot before editing."
  (let ((marker (zk-org-locate reference)))
    (when-let* ((revision (and (listp reference) (plist-get reference :revision))))
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char marker)
         (unless (equal revision (if (eq (plist-get reference :scope) 'file)
                                     (secure-hash 'sha256
                                                  (buffer-substring-no-properties (point-min) (point-max)))
                                   (plist-get (zk-org-entry) :revision)))
           (user-error "Entry changed; refresh before editing")))))
    marker))

(defun zk-org-query (file predicate)
  "Read heading snapshots in FILE that satisfy PREDICATE at point."
  (when (file-readable-p file)
    (with-current-buffer (zk-org-buffer file)
      (org-with-wide-buffer
       (let (entries)
         (org-map-entries
          (lambda ()
            (unless (or (org-in-commented-heading-p) (org-in-archived-heading-p))
              (when (funcall predicate) (push (zk-org-entry) entries))))
          nil 'file)
         (nreverse entries))))))

(defun zk-entry-read (reference)
  "Read current content for REFERENCE without applying a write-version check."
  (if (eq (plist-get (and (listp reference) reference) :scope) 'file)
      (with-current-buffer (find-file-noselect (plist-get reference :file))
        (save-restriction
          (widen)
          (append (list :revision (secure-hash 'sha256 (current-buffer))
                        :body (buffer-substring-no-properties (point-min) (point-max)))
                  reference)))
    (let ((marker (zk-org-locate reference)))
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char marker)
         (append (zk-org-entry)
                 (list :body (buffer-substring-no-properties
                              (point) (if (org-before-first-heading-p)
                                          (point-max)
                                        (zk-org-subtree-end))))))))))

(defun zk-org-transaction (files function)
  "Apply FUNCTION across FILES atomically in memory, then save clean buffers.
Return FUNCTION's plist plus :saved and :save-errors. Earlier unsaved edits
remain unsaved. Save failures are reported without repeating a successful edit."
  (let* ((files (delete-dups files))
         (buffers
          (mapcar (lambda (f) (make-directory (file-name-directory f) t) (find-file-noselect f)) files))
         (pending (mapcar #'buffer-modified-p buffers))
         (snapshots (mapcar (lambda (b) (with-current-buffer b
                                          (save-restriction
                                            (widen)
                                            (list (buffer-string) buffer-undo-list
                                                  (buffer-modified-p)))))
                            buffers))
         handles result committed)
    (dolist (buffer buffers)
      (unless (with-current-buffer buffer (verify-visited-file-modtime buffer))
        (user-error "A source file changed on disk; revert or reconcile it first"))
      (when (buffer-local-value 'buffer-read-only buffer)
        (user-error "A source buffer is read-only")))
    (unwind-protect
        (let ((zk-org-transaction-active t))
          (dolist (buffer buffers)
            (let ((handle (with-current-buffer buffer (prepare-change-group))))
              (activate-change-group handle) (push handle handles)))
          (setq result (funcall function))
          (mapc #'accept-change-group handles)
          (setq committed t))
      (unless committed
        (condition-case nil (mapc #'cancel-change-group handles)
          (error
           (cl-mapc (lambda (buffer snapshot)
                      (with-current-buffer buffer
                        (let ((inhibit-modification-hooks t) (buffer-undo-list t))
                          (save-restriction (widen) (erase-buffer) (insert (car snapshot))))
                        (setq buffer-undo-list (nth 1 snapshot))
                        (set-buffer-modified-p (nth 2 snapshot))
                        (when (derived-mode-p 'org-mode) (org-element-cache-reset))))
                    buffers snapshots)))))
    (let (errors)
      (cl-mapc (lambda (buffer was-modified)
                 (unless was-modified
                   (condition-case err
                       (with-current-buffer buffer
                         (let ((make-backup-files nil) (backup-inhibited t)) (save-buffer)))
                     (error (push (error-message-string err) errors)))))
               buffers pending)
      (zk-library-notify files)
      (append result
              (list :saved (not (seq-some #'buffer-modified-p buffers)) :save-errors
                    (nreverse errors))))))

(defun zk-org-ensure-container (title)
  "Find or create a real top-level TITLE, ignoring tags and their alignment."
  (let ((position
         (org-element-map (org-element-parse-buffer 'headline) 'headline
                          (lambda (heading)
                            (when (and (= 1 (org-element-property :level heading))
                                       (not (org-element-property :todo-keyword heading))
                                       (not (org-element-property :commentedp heading))
                                       (equal title (string-trim (org-element-property :raw-value heading))))
                              (org-element-property :begin heading)))
                          nil t)))
    (if position (goto-char position)
      (goto-char (point-max)) (unless (bolp) (insert "\n"))
      (insert "\n* " title "\n") (forward-line -1)))
  (point-marker))

(defun zk-org-append-child (parent title &optional body type)
  "Create a child of PARENT (a marker), assigning an Org ID. Return its marker."
  (goto-char parent)
  (let ((level (1+ (org-outline-level))))
    (goto-char (zk-org-subtree-end)) (unless (bolp) (insert "\n")) (insert "\n")
    (let ((start (point)))
      (insert (make-string level ?*) " " title "\n")
      (goto-char start) (zk-org-ensure-id)
      (when type (org-entry-put nil "ZK_TYPE" type))
      (org-entry-put nil "CREATED" (format-time-string "[%Y-%m-%d %a %H:%M]"))
      (goto-char (zk-org-subtree-end))
      (when (and body (not (string-empty-p body)))
        (insert body) (unless (bolp) (insert "\n")))
      (goto-char start) (point-marker))))

(defun zk-org-validate-date (value)
  "Validate a date/time input; preserve supported Org repeater/range suffixes."
  (when (and value (not (equal value "")))
    (unless (and (stringp value)
                 (string-match
                  "\\`\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)\\(?: \\([0-9]\\{2\\}:[0-9]\\{2\\}\\)\\(?:-\\([0-9]\\{2\\}:[0-9]\\{2\\}\\)\\)?\\)?\\(?: \\([.+]+[0-9]+[hdwmy]\\)\\)?\\'"
                  value))
      (user-error "Use YYYY-MM-DD [HH:MM[-HH:MM]] [+1w]"))
    (let
        ((day (match-string 1 value)) (start (match-string 2 value)) (end (match-string 3 value))
         (repeat (match-string 4 value)))
      (when
          (and repeat (not (member (replace-regexp-in-string "[0-9].*" "" repeat) '("+" "++" ".+"))))
        (user-error "Invalid repeater"))
      (unless (equal day (format-time-string "%Y-%m-%d" (org-time-string-to-time day)))
        (user-error "Invalid date"))
      (dolist (clock (delq nil (list start end)))
        (let
            ((h (string-to-number (substring clock 0 2))) (m (string-to-number (substring clock 3))))
          (unless (and (< m 60) (or (< h 24) (and (equal clock end) (= h 24) (= m 0))))
            (user-error "Invalid time"))))))
  value)

(defun zk-org-set-dates (scheduled deadline)
  (dolist (entry `(("SCHEDULED" ,scheduled org-schedule) ("DEADLINE" ,deadline org-deadline)))
    (let ((property (nth 0 entry)) (value (nth 1 entry)) (command (nth 2 entry)))
      (when value
        (funcall command (and (equal value "") '(4)) value)
        ;; org-schedule reads date/time but ignores an explicitly supplied repeater.
        ;; Add that validated suffix to the timestamp using Org's property API.
        (when (string-match " \\([.+]+[0-9]+[hdwmy]\\)\\'" value)
          (let ((repeat (match-string 1 value)) (stamp (org-entry-get nil property)))
            (setq stamp (replace-regexp-in-string " [.+]+[0-9]+[hdwmy]" "" stamp))
            (org-entry-put nil property (concat (substring stamp 0 -1) " " repeat ">"))))))))

(defun zk-org-set-state (state)
  "Use native Org transitions with a temporary local keyword parser."
  (unwind-protect
      (let ((org-todo-setup-filter-hook '(zk-org-todo-sequence)))
        (org-set-regexps-and-options)
        (org-todo (or state 'none))
        (when (and org-log-setup (not (eq org-log-note-how 'note))) (org-add-log-note)))
    (org-set-regexps-and-options)))

(defun zk-org-edit-todo (reference &optional prefix)
  "Run native Org state selection for REFERENCE without visiting its window.
Use source-local keywords, logging and repeaters.
Preserve earlier unsaved edits."
  (let ((marker (zk-org-resolve reference)))
    (zk-org-transaction
     (list (buffer-file-name (marker-buffer marker)))
     (lambda ()
       (with-current-buffer (marker-buffer marker)
         (org-with-wide-buffer
          (goto-char marker)
          (unless (zk-org-state) (user-error "Select a task"))
          (let ((current-prefix-arg prefix)
                (org-loop-over-headlines-in-active-region nil))
            (call-interactively #'org-todo)
            (when (and org-log-setup (not (eq org-log-note-how 'note)))
              (org-add-log-note)))
          (zk-org-entry)))))))

(defun zk-org-insert-subtree (parent tree)
  (goto-char parent)
  (let ((level (1+ (org-outline-level))))
    (goto-char (zk-org-subtree-end)) (unless (bolp) (insert "\n")) (insert "\n")
    (org-paste-subtree level tree)
    (org-back-to-heading t)))

(defun zk-org-take-subtree (marker)
  "Remove and return MARKER's subtree, assigning an ID if needed.
Call only inside a transaction that includes the source and destination."
  (with-current-buffer (marker-buffer marker)
    (org-with-wide-buffer
     (goto-char marker)
     (zk-org-ensure-id)
     (prog1 (buffer-substring-no-properties (point) (zk-org-subtree-end))
       (delete-region (point) (zk-org-subtree-end))))))

(provide 'zk-org-store)
;;; zk-org-store.el ends here
