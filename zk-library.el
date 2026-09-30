;;; zk-library.el --- Library paths, file discovery and change notifications -*- lexical-binding: t; -*-

;;; Commentary:
;; Library paths, file discovery and change notifications

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)

(defgroup zk nil "Knowledge and actions in ordinary Org files." :group 'org)

(defcustom zk-root (expand-file-name "~/Zettelkasten/")
  "Knowledge library." :type 'directory :group 'zk)

(defcustom zk-inbox-file "org-notes/my-inbox.org"
  "Inbox, relative to `zk-root' or absolute." :type 'string :group 'zk)

(defcustom zk-agenda-file "org-notes/my-agenda.org"
  "Agenda, relative to `zk-root' or absolute." :type 'string :group 'zk)

(defcustom zk-org-note-directory "org-notes/"
  "New Org notes, relative to `zk-root'." :type 'string :group 'zk)

(defcustom zk-markdown-note-directory "md-notes/"
  "New Markdown notes, relative to `zk-root'." :type 'string :group 'zk)

(defvar zk-change-hook nil
  "Functions called with changed file paths after a successful transaction.")

(defun zk-path (path) (expand-file-name path zk-root))

(defun zk-inbox-path () (zk-path zk-inbox-file))

(defun zk-agenda-path () (zk-path zk-agenda-file))

(defun zk-library-same-file-p (a b)
  (equal (file-truename a) (file-truename b)))

(defun zk-library-file-p (file)
  (and file (or (file-in-directory-p file zk-root)
                (zk-library-same-file-p file (zk-inbox-path))
                (zk-library-same-file-p file (zk-agenda-path)))))

(defun zk-files (&optional org-only)
  "Library documents plus shared workflow files; omit lock and autosave files."
  (delete-dups
   (append (seq-filter #'file-readable-p (list (zk-inbox-path) (zk-agenda-path)))
           (when (file-directory-p zk-root)
             (seq-filter (lambda (f) (not (string-match-p "\\`[.#]" (file-name-nondirectory f))))
                         (directory-files-recursively zk-root
                                                      (if org-only "\\.org\\'"
                                                        "\\.\\(?:org\\|md\\)\\'")))))))

(defun zk-library-notify (files)
  "UI refresh errors must not turn a successful write into a failed operation."
  (dolist (function zk-change-hook)
    (condition-case err (funcall function files)
      (error (message "ZK display refresh failed: %s" (error-message-string err))))))

(defun zk-library-validate-title (title)
  (unless (and (stringp title) (not (string-empty-p (string-trim title)))
               (not (string-match-p "[\n\r]" title)))
    (user-error "Enter a nonempty, single-line title"))
  (string-trim title))

(defun zk-library-file-version (file)
  "A cache key for FILE's disk contents and live buffer, ignoring access time."
  (let ((attributes (file-attributes file)) (buffer (get-file-buffer file)))
    (list (nth 5 attributes) (nth 6 attributes) (nth 7 attributes) (nth 10 attributes)
          buffer
          (and buffer (with-current-buffer buffer (buffer-chars-modified-tick)))
          (and buffer (buffer-modified-p buffer)))))

(provide 'zk-library)
;;; zk-library.el ends here
