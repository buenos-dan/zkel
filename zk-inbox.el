;;; zk-inbox.el --- Capture and clarify raw information -*- lexical-binding: t; -*-

;;; Commentary:
;; Capture and clarify raw information

;;; Code:
(require 'zk-tasks)
(require 'zk-notes)

(defun zk-inbox--entry-p ()
  "Whether point is an unprocessed Inbox root, excluding comments and archives."
  (and (not (org-before-first-heading-p))
       (not (org-in-commented-heading-p))
       (not (org-in-archived-heading-p))
       (or (and (= (org-outline-level) 2)
                (equal (car (org-get-outline-path)) "Inbox"))
           (and (= (org-outline-level) 1) (not (equal (zk-org-title) "Inbox"))))))

(defun zk-inbox--source (reference)
  "Resolve and validate an unprocessed source for a write."
  (let ((marker (zk-org-resolve reference)))
    (unless (and (zk-library-same-file-p (buffer-file-name (marker-buffer marker)) (zk-inbox-path))
                 (with-current-buffer (marker-buffer marker)
                   (org-with-wide-buffer (goto-char marker) (zk-inbox--entry-p))))
      (user-error "Select an unprocessed Inbox entry"))
    marker))

(defun zk-inbox-entries ()
  "Return unprocessed Inbox entry records."
  (zk-org-query (zk-inbox-path) #'zk-inbox--entry-p))

(defun zk-capture (title &optional body request-id)
  "Collect raw information. No task state or schedule is inferred.
REQUEST-ID deduplicates retries by searching the library's saved/live entries."
  (setq title (zk-library-validate-title title))
  (let ((prior (and request-id
                    (seq-some (lambda (file)
                                (or
                                 (with-current-buffer (zk-org-buffer file)
                                   (org-with-wide-buffer
                                    (goto-char (point-min))
                                    (when (and (org-before-first-heading-p)
                                               (equal request-id (org-entry-get nil "ZK_REQUEST")))
                                      (zk-org-entry))))
                                 (car
                                  (zk-org-query file
                                                (lambda ()
                                                  (equal request-id (org-entry-get nil "ZK_REQUEST")))))))
                              (zk-files t)))))
    (or
     (and prior
          (append prior
                  (list :saved (not (buffer-modified-p (zk-org-buffer (plist-get prior :file))))
                        :duplicate t)))
     (zk-org-transaction
      (list (zk-inbox-path))
      (lambda ()
        (with-current-buffer (zk-org-buffer (zk-inbox-path))
          (org-with-wide-buffer
           (zk-org-append-child (zk-org-ensure-container "Inbox") title body "inbox")
           (when request-id (org-entry-put nil "ZK_REQUEST" request-id))
           (zk-org-entry))))))))


(defun zk-inbox--shift-headings (text offset)
  "Shift actual Org headings in TEXT by OFFSET, leaving examples untouched."
  (with-temp-buffer
    (let ((org-mode-hook nil) (org-inhibit-startup t)) (org-mode))
    (insert text)
    (let ((headings (org-element-map (org-element-parse-buffer) 'headline
                                     (lambda (heading)
                                       (cons (org-element-property :begin heading)
                                             (org-element-property :level heading))))))
      (dolist (heading (reverse headings))
        (goto-char (car heading))
        (delete-char (cdr heading))
        (insert (make-string (max 1 (+ offset (cdr heading))) ?*))))
    (buffer-string)))

(defun zk-inbox-edit-text (reference)
  "Return an editable summary and body for REFERENCE, hiding root metadata.
Child headings start at level one; their IDs and drawers remain in the text."
  (let ((marker (zk-org-locate reference)))
    (with-current-buffer (marker-buffer marker)
      (org-with-wide-buffer
       (goto-char marker)
       (let ((title (zk-org-title)) (level (org-outline-level))
             (end (zk-org-subtree-end)))
         (org-end-of-meta-data)
         (concat title "\n"
                 (zk-inbox--shift-headings
                  (buffer-substring-no-properties (point) end) (- level))))))))

(defun zk-inbox--parse-text (text)
  "Split TEXT at its first nonempty line into a summary and an Org body."
  (unless (and (stringp text) (not (string-empty-p (string-trim text))))
    (user-error "Write a message first"))
  (let* ((text (replace-regexp-in-string "\\`\\(?:[ \t]*\n\\)+" "" text))
         (newline (string-match "\n" text)))
    (list (zk-library-validate-title (if newline (substring text 0 newline) text))
          (if newline (substring text (1+ newline)) ""))))

(defun zk-inbox--edited-tree (text source)
  "Build a level-one subtree for TEXT, retaining SOURCE's root metadata."
  (pcase-let ((`(,title ,body) (zk-inbox--parse-text text)))
    (let ((original (when source
                      (with-current-buffer (marker-buffer source)
                        (org-with-wide-buffer
                         (goto-char source)
                         (buffer-substring-no-properties (point) (zk-org-subtree-end)))))))
      (with-temp-buffer
        (let ((org-mode-hook nil) (org-inhibit-startup t)) (org-mode))
        (if original
            (progn
              (org-paste-subtree 1 original) (org-back-to-heading t)
              (org-edit-headline title))
          (insert "* " title "\n") (goto-char (point-min))
          (org-entry-put nil "ZK_TYPE" "inbox")
          (org-entry-put nil "CREATED" (format-time-string "[%Y-%m-%d %a %H:%M]")))
        (zk-org-ensure-id)
        (org-end-of-meta-data)
        (delete-region (point) (point-max))
        (unless (bolp) (insert "\n"))
        (insert (zk-inbox--shift-headings body 1))
        (unless (bolp) (insert "\n"))
        (buffer-string)))))

(defun zk-inbox--destination (destination)
  "Validate DESTINATION and return its live parent, if already present."
  (unless destination (user-error "Choose an area or project"))
  (let ((area (plist-get destination :new-area))
        (project (plist-get destination :new-project)) marker)
    (when area (zk-library-validate-title area))
    (when project (zk-library-validate-title project))
    (unless area
      ;; Child edits do not change a container's identity or suitability.
      (setq marker (zk-org-locate (if project (plist-get destination :parent) destination)))
      (unless (zk-library-same-file-p (buffer-file-name (marker-buffer marker)) (zk-agenda-path))
        (user-error "Choose a destination in the agenda"))
      (with-current-buffer (marker-buffer marker)
        (org-with-wide-buffer
         (goto-char marker)
         (when (or (org-in-archived-heading-p) (org-in-commented-heading-p)
                   (zk-org-state) (org-entry-get nil "SCHEDULED")
                   (org-entry-get nil "DEADLINE"))
           (user-error "Choose an area or project container")))))
    marker))

(defun zk-inbox-submit (text &rest options)
  "Save TEXT once, either as a new item or an edited Inbox REFERENCE.
OPTIONS: :reference, :target (inbox/agenda/note/archive), :destination,
:kind (task/project/event), :state, :scheduled, :deadline and :filename.
All edits, destination creation and moves share one transaction."
  (let* ((reference (plist-get options :reference))
         (source (and reference (zk-inbox--source reference)))
         (target (or (plist-get options :target) 'inbox))
         (kind (or (plist-get options :kind) 'task))
         (state (or (plist-get options :state) "TODO"))
         (destination (plist-get options :destination))
         (scheduled (plist-get options :scheduled)) (deadline (plist-get options :deadline))
         (filename (plist-get options :filename)) parent file tree result)
    (unless (memq target '(inbox agenda note archive)) (user-error "Choose where to save"))
    (zk-inbox--parse-text text)
    (when (eq target 'agenda)
      (unless (memq kind '(task project event)) (user-error "Choose task, project or event"))
      (unless (member state (zk-org-states 'active)) (user-error "Choose TODO or NEXT"))
      (zk-org-validate-date scheduled) (zk-org-validate-date deadline)
      (when (and (eq kind 'event)
                 (not (or (and scheduled (not (equal scheduled "")))
                          (and (null scheduled) source
                               (with-current-buffer (marker-buffer source)
                                 (org-with-wide-buffer (goto-char source)
                                                       (org-entry-get nil "SCHEDULED")))))))
        (user-error "An event needs its actual date or time"))
      (setq parent (zk-inbox--destination destination)))
    (when (and (eq target 'archive) (not source)) (user-error "Save an item before archiving"))
    (when (eq target 'note)
      (when (and source (not (and filename (string-suffix-p ".org" filename))))
        (user-error "Use .org to preserve the Inbox content and its ID"))
      (setq file (zk-note-new-path filename)))
    (unless file (setq file (if (eq target 'inbox) (zk-inbox-path) (zk-agenda-path))))
    (setq tree (unless (and (eq target 'note) (not source)) (zk-inbox--edited-tree text source)))
    (setq result
          (zk-org-transaction
           (delete-dups (append (and source (list (zk-inbox-path))) (list file)))
           (lambda ()
             (let ((level (when source
                            (with-current-buffer (marker-buffer source)
                              (org-with-wide-buffer (goto-char source) (org-outline-level))))))
               (when source
                 (with-current-buffer (marker-buffer source)
                   (org-with-wide-buffer
                    (goto-char source) (delete-region (point) (zk-org-subtree-end)))))
               (if (eq target 'note)
                   (zk-note-initialize file (unless source text) tree)
                 (with-current-buffer (zk-org-buffer file)
                   (org-with-wide-buffer
                    (pcase target
                      ('inbox
                       (if source (progn
                                    (goto-char source) (org-paste-subtree level tree)
                                    (org-back-to-heading t))
                         (zk-org-insert-subtree (zk-org-ensure-container "Inbox") tree)))
                      ('agenda
                       (when (plist-get destination :new-area)
                         (setq parent (zk-org-ensure-container (plist-get destination :new-area)))
                         (zk-org-ensure-id))
                       (when (plist-get destination :new-project)
                         (setq parent
                               (zk-org-append-child parent (plist-get destination :new-project) nil
                                                    "project")))
                       (zk-org-insert-subtree parent tree)
                       (org-entry-put nil "ZK_TYPE" (symbol-name kind))
                       (zk-org-set-state (and (eq kind 'task) state))
                       (unless (eq kind 'project) (zk-org-set-dates scheduled deadline)))
                      ('archive
                       (let ((archive (zk-org-ensure-container "Archive")))
                         (org-set-tags (cons "ARCHIVE" (remove "ARCHIVE" (org-get-tags nil t))))
                         (zk-org-insert-subtree archive tree))))
                    (zk-org-entry))))))))
    (if (eq target 'note) (zk-note-result file result) result)))

(defun zk-inbox-process (reference destination &rest properties)
  "Move an Inbox REFERENCE into an agenda DESTINATION with PROPERTIES."
  (let ((text (zk-inbox-edit-text reference)))
    (when (plist-get properties :title)
      (setq text (concat (zk-library-validate-title (plist-get properties :title)) "\n"
                         (cadr (zk-inbox--parse-text text)))))
    (apply #'zk-inbox-submit text :reference reference :target 'agenda
           :destination destination properties)))

(defun zk-inbox-archive (reference)
  "Move an Inbox REFERENCE into the recoverable Archive tree."
  (zk-inbox-submit (zk-inbox-edit-text reference) :reference reference :target 'archive))

(defun zk-inbox-to-note (reference filename)
  "Move an Inbox REFERENCE to an Org FILENAME, preserving its identity."
  (zk-inbox-submit (zk-inbox-edit-text reference) :reference reference
                   :target 'note :filename filename))

(provide 'zk-inbox)
;;; zk-inbox.el ends here
