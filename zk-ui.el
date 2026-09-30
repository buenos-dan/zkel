;;; zk-ui.el --- Shared selection, navigation and input -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared selection, navigation and input

;;; Code:
(require 'zk-notes)

(defun zk-ui-choose (prompt entries)
  (unless entries (user-error "No matching entries"))
  (let ((choices (cl-loop for entry in entries for n from 1
                          collect (cons (format "%s  [%d]"
                                                (string-join (if (eq (plist-get entry :record) 'note)
                                                                 (list
                                                                  (file-relative-name (plist-get entry :file)
                                                                                      zk-root))
                                                               (or (plist-get entry :path)
                                                                   (list (plist-get entry :title))))
                                                             " / ")
                                                n)
                                        entry))))
    (cdr (assoc (completing-read prompt choices nil t) choices))))

(defun zk-ui-current-entry ()
  "Return the explicit record at point or the current Org heading snapshot."
  (or (get-text-property (point) 'zk-entry)
      (and buffer-file-name (derived-mode-p 'org-mode)
           (if (org-before-first-heading-p)
               (and (member buffer-file-name (zk-note-files))
                    (zk-note-metadata buffer-file-name))
             (save-excursion (org-back-to-heading t) (zk-org-entry))))))

(defun zk-ui-open (record)
  "Open RECORD according to its kind, without checking an editing revision."
  (pcase (plist-get record :record)
    ('entry
     (let ((marker (zk-org-locate record)))
       (pop-to-buffer-same-window (marker-buffer marker))
       (widen) (goto-char marker)
       (unless (org-before-first-heading-p)
         (org-fold-show-context 'agenda) (org-fold-show-entry))))
    ((or 'note 'link)
     (find-file (plist-get record :file))
     (when (plist-get record :line)
       (widen) (goto-char (point-min))
       (forward-line (1- (plist-get record :line)))))
    (_ (user-error "Unknown ZK record kind; refresh the view"))))

(defun zk-ui-report (result)
  (message (if (plist-get result :saved) "Saved."
             "Updated in memory; save the changed documents when ready.")))

(defvar zk-note-file-history nil)

(defvar zk-new-note-file-history nil)

(defun zk-ui-read-new-note-filename (&optional initial org-only)
  "Read a new note filename, prefilled with INITIAL when provided.
ORG-ONLY is used when preserving an Inbox subtree as an Org document."
  (let ((filename (read-string (if org-only "Note filename (.org): "
                                "Note filename (.org or .md): ")
                              initial 'zk-new-note-file-history)))
    (zk-note-new-path filename)
    (when (and org-only (not (string-suffix-p ".org" filename)))
      (user-error "Use .org to preserve the Inbox content and its ID"))
    filename))

(defun zk-ui-read-note-file ()
  "Choose a note by relative filename, with case-insensitive substring matching."
  (let* ((choices (mapcar (lambda (file) (cons (file-relative-name file zk-root) file))
                          (sort (zk-note-files) #'string-lessp)))
         (completion-ignore-case t)
         (completion-styles '(substring basic))
         (completion-category-defaults nil)
         (completion-category-overrides '((zk-note-file (styles substring basic))))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      '(metadata (category . zk-note-file))
                    (complete-with-action action choices string predicate)))))
    (unless choices (user-error "No notes yet; press n to create one"))
    (cdr (assoc (completing-read "Find note file: " table nil t nil 'zk-note-file-history) choices))))

(defun zk-follow-id ()
  "Resolve a library ID link using current files, without a separate index."
  (let ((context (org-element-context)))
    (when (and (eq (org-element-type context) 'link)
               (equal (org-element-property :type context) "id"))
      (when-let*
          ((marker
            (condition-case nil (zk-org-locate (org-element-property :path context))
              (user-error nil))))
        (pop-to-buffer-same-window (marker-buffer marker))
        (widen) (goto-char marker)
        (unless (org-before-first-heading-p) (org-fold-show-context 'agenda) (org-fold-show-entry))
        t))))

(defvar org-read-date-final-answer)
(defvar org-end-time-was-given)

(defun zk-ui-read-date (prompt)
  "Read and validate an Org date, preserving ranges and repeaters."
  (let* ((org-read-date-final-answer nil) (org-end-time-was-given nil)
         (org-read-date-popup-calendar t)
         (value (org-read-date nil nil nil prompt)))
    (when org-end-time-was-given (setq value (concat value "-" org-end-time-was-given)))
    (when (and org-read-date-final-answer
               (string-match " \\([.+]+[0-9]+[hdwmy]\\)\\'" (string-trim org-read-date-final-answer)))
      (setq value (concat value " " (match-string 1 (string-trim org-read-date-final-answer)))))
    (zk-org-validate-date value)))

(provide 'zk-ui)
;;; zk-ui.el ends here
