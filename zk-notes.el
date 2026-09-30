;;; zk-notes.el --- Note files, metadata and backlinks -*- lexical-binding: t; -*-

;;; Commentary:
;; Note records describe whole files.  Entry records describe Org headings.
;; Cached metadata is invalidated by file attributes and live buffer changes.

;;; Code:
(require 'zk-org-store)

(defvar zk-notes--cache (make-hash-table :test #'equal))

(defun zk-note-files ()
  "Return knowledge documents, excluding the two workflow files."
  (seq-remove (lambda (file)
                (or (zk-library-same-file-p file (zk-inbox-path))
                    (zk-library-same-file-p file (zk-agenda-path))))
              (zk-files)))

(defun zk-notes-clear-cache ()
  "Discard cached metadata; explicit refresh calls this before querying."
  (clrhash zk-notes--cache))

(defun zk-notes--read-metadata (file live)
  "Read a whole-file record from the current buffer, using LIVE for dirty state."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let ((case-fold-search t) title tags id)
        (if (string-suffix-p ".org" file)
            (progn
              (unless (derived-mode-p 'org-mode)
                (let ((org-mode-hook nil) (org-inhibit-startup t)) (org-mode)))
              (let ((keywords (org-collect-keywords '("TITLE" "FILETAGS"))))
                (setq title (cadr (assoc "TITLE" keywords))
                      tags
                      (split-string (string-join (cdr (assoc "FILETAGS" keywords)) ":") "[: \t]+" t)))
              ;; A note's identity is the file ID or its first root heading's ID,
              ;; never an arbitrary ID found later inside the document.
              (goto-char (point-min))
              (setq id (and (org-before-first-heading-p) (org-entry-get nil "ID")))
              (unless id
                (when (re-search-forward "^\\* " nil t)
                  (beginning-of-line)
                  (setq id (org-entry-get nil "ID")))))
          (when (re-search-forward "^# +\\(.+\\)$" nil t)
            (setq title (match-string-no-properties 1))))
        (list :record 'note :scope 'file :file file :filename (file-name-nondirectory file)
              :title (or title (file-name-base file)) :tags tags :id id :position (point-min)
              :revision
              (secure-hash 'sha256 (buffer-substring-no-properties (point-min) (point-max)))
              :modified (and live (buffer-modified-p live))
              :mtime (file-attribute-modification-time (file-attributes file)))))))

(defun zk-note-metadata (file)
  "Return a note record, preferring live contents and reusing unchanged metadata."
  (let* ((file (expand-file-name file))
         (live (get-file-buffer file))
         (version (zk-library-file-version file))
         (cached (gethash file zk-notes--cache)))
    (unless (equal version (car cached))
      (setq cached
            (cons version
                  (if live
                      (with-current-buffer live (zk-notes--read-metadata file live))
                    (with-temp-buffer
                      (insert-file-contents file)
                      (zk-notes--read-metadata file nil)))))
      (puthash file cached zk-notes--cache))
    ;; Consumers may annotate a record; do not let that mutate the cache.
    (copy-tree (cdr cached))))

(defun zk-notes ()
  "Return note records by file modification time, newest first."
  (let* ((files (zk-note-files))
         (records (mapcar #'zk-note-metadata files)))
    (maphash (lambda (file _) (unless (member file files) (remhash file zk-notes--cache)))
             zk-notes--cache)
    (sort records
          (lambda (a b)
            (if (equal (plist-get a :mtime) (plist-get b :mtime))
                (string-lessp (plist-get a :file) (plist-get b :file))
              (time-less-p (plist-get b :mtime) (plist-get a :mtime)))))))

(defun zk-note-new-path (filename)
  "Validate FILENAME and return its exact new-note path without creating it."
  (unless (and (stringp filename)
               (equal filename (string-trim filename))
               (not (file-name-absolute-p filename))
               (not (string-match-p "[\n\r/\\\x00]" filename))
               (not (string-match-p "\\`[.#~]" filename))
               (> (length (file-name-base filename)) 0))
    (user-error "Enter a filename without directories or leading/trailing spaces"))
  (let* ((directory (pcase (file-name-extension filename)
                      ("org" zk-org-note-directory)
                      ("md" zk-markdown-note-directory)
                      (_ (user-error "End the filename with .org or .md"))))
         (file (expand-file-name filename (zk-path directory))))
    (when (or (file-exists-p file) (file-symlink-p file) (get-file-buffer file))
      (user-error "A note named %s already exists or is open" filename))
    file))

(defun zk-note-inbox-filename (title)
  "Suggest an editable Org filename from an Inbox TITLE."
  (let ((base (string-trim (replace-regexp-in-string "[[:space:]/\\]+" "-" title) "[.#-]+" "-+")))
    (concat (if (string-empty-p base) "note" base) ".org")))

(defun zk-note--org-template (&optional properties)
  "Insert file-level metadata, retaining existing PROPERTIES when importing."
  (insert ":PROPERTIES:\n:END:\n\n")
  (goto-char (point-min))
  (dolist (property properties)
    (unless (member (car property) '("CATEGORY" "ZK_TYPE"))
      (org-entry-put nil (car property) (cdr property))))
  (unless (org-entry-get nil "ID") (org-entry-put nil "ID" (org-id-new)))
  (org-entry-put nil "ZK_TYPE" "fleeting-note")
  (dolist (property `(("MDS" . "nil") ("TOPICS" . "nil")
                      ("DATE" . ,(format-time-string "%Y-%m-%d"))))
    (unless (org-entry-get nil (car property))
      (org-entry-put nil (car property) (cdr property))))
  (goto-char (point-max)))

(defun zk-note--unpack-subtree (subtree)
  "Return SUBTREE's file metadata and body, preserving nested heading IDs."
  (with-temp-buffer
    (let ((org-mode-hook nil) (org-inhibit-startup t)) (org-mode))
    (org-paste-subtree 1 subtree)
    (goto-char (point-min))
    (re-search-forward org-heading-regexp)
    (beginning-of-line)
    (let* ((properties (org-entry-properties nil 'standard))
           (tags (org-get-tags nil t))
           (block (org-get-property-block))
           (heading-end (save-excursion (forward-line 1) (point))))
      ;; Delete only the root drawer and heading; planning/logbook/body survive.
      (when block
        (delete-region (save-excursion (goto-char (car block)) (forward-line -1) (point))
                       (save-excursion (goto-char (cdr block)) (forward-line 1) (point))))
      (delete-region (point-min) heading-end)
      (goto-char (point-min))
      (org-map-entries #'org-promote nil nil)
      (list properties (buffer-substring-no-properties (point-min) (point-max)) tags))))

(defun zk-note-initialize (file &optional body subtree)
  "Initialize a new FILE with BODY or an imported Org SUBTREE.
The caller owns the transaction. Notes have no wrapper heading."
  (with-current-buffer (find-file-noselect file)
    (unless (= (point-min) (point-max)) (user-error "New note file is not empty"))
    (if (string-suffix-p ".org" file)
        (progn
          (unless (derived-mode-p 'org-mode) (org-mode))
          (if subtree
              (pcase-let ((`(,properties ,contents ,tags) (zk-note--unpack-subtree subtree)))
                (zk-note--org-template (cons '("SOURCE" . "Inbox") properties))
                (when tags (insert "#+filetags: :" (string-join tags ":") ":\n\n"))
                (insert contents))
            (zk-note--org-template)
            (when body (insert body))))
      (when subtree (user-error "Inbox extraction requires an .org filename"))
      (when body (insert body)))
    (unless (or (= (point-min) (point-max)) (bolp)) (insert "\n"))
    (list :record 'note :scope 'file :file file)))

(defun zk-note-result (file operation)
  "Return FILE's current note record with OPERATION's save status."
  (append (zk-note-metadata file)
          (list :saved (plist-get operation :saved)
                :save-errors (plist-get operation :save-errors))))

(defun zk-note-create (filename &optional body)
  "Create exactly FILENAME in its format directory and return the note record."
  (let* ((file (zk-note-new-path filename))
         (result (zk-org-transaction (list file)
                                     (lambda () (zk-note-initialize file body)))))
    (zk-note-result file result)))

(defun zk-backlinks (reference)
  "Find Org ID links to REFERENCE without changing any document."
  (let ((id (if (stringp reference) reference (plist-get reference :id))) results)
    (unless id (user-error "This entry needs an ID before it can have stable backlinks"))
    (dolist (file (zk-files))
      (let ((live (get-file-buffer file)))
        (with-temp-buffer
          (if live (insert (with-current-buffer live (save-restriction (widen) (buffer-string))))
            (insert-file-contents file))
          (goto-char (point-min))
          (while (search-forward (concat "[[id:" id "]") nil t)
            (push (list :record 'link :file file :line (line-number-at-pos)
                        :text
                        (string-trim
                         (buffer-substring-no-properties (line-beginning-position)
                                                         (line-end-position))))
                  results)))))
    (nreverse results)))

(provide 'zk-notes)
;;; zk-notes.el ends here
