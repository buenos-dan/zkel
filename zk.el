;;; zk.el --- Collect, clarify, act and connect knowledge -*- lexical-binding: t; -*-
;; Author: buenos-dan
;; Version: 0.2.0
;; Package-Requires: ((emacs "30.1"))
;; URL: https://github.com/buenos-dan/zkel
;; Keywords: outlines, convenience
;;; Commentary:
;; Org files are the source of truth. Enable `zk-mode' explicitly.
;;; Code:
(require 'zk-inbox)
(require 'zk-agenda)
(require 'zk-ui)
(require 'remember)
(autoload 'zk-home "zk-home" nil t)
(autoload 'zk-home-start "zk-home")
(autoload 'zk-home-stop "zk-home")
(autoload 'zk-menu "zk-commands" nil t)

(defvar-local zk--document-settings nil)
(defvar zk--workflow-settings nil)

(defun zk--workflow-enable ()
  "Bind Org collection and calendar paths to the configured library."
  (unless zk--workflow-settings
    (dolist (setting `((org-agenda-files . (,(zk-agenda-path)))
                       (org-default-notes-file . ,(zk-inbox-path))
                       (remember-data-file . ,(zk-inbox-path))))
      (push (list (car setting) (default-value (car setting)) (cdr setting)) zk--workflow-settings)
      (set-default (car setting) (cdr setting)))))

(defun zk--workflow-disable ()
  "Restore path preferences unless they were subsequently changed."
  (dolist (setting zk--workflow-settings)
    (when (equal (default-value (car setting)) (nth 2 setting))
      (set-default (car setting) (nth 1 setting))))
  (setq zk--workflow-settings nil))
(defun zk--document-enable ()
  "Apply knowledge-library recovery preferences and ID navigation."
  (when (zk-library-file-p buffer-file-name)
    (unless zk--document-settings
      (setq zk--document-settings
            (mapcar (lambda (s) (list s (local-variable-p s) (symbol-value s)))
                    '(make-backup-files backup-inhibited auto-save-default header-line-format
                                        org-open-at-point-functions))))
    (setq-local make-backup-files nil backup-inhibited t auto-save-default nil header-line-format
                nil)
    (auto-save-mode -1)
    (when (derived-mode-p 'org-mode)
      (add-hook 'org-open-at-point-functions #'zk-follow-id nil t))))
(defun zk--document-disable ()
  (when zk--document-settings
    (dolist (setting zk--document-settings)
      (if (nth 1 setting) (set (make-local-variable (car setting)) (nth 2 setting))
        (kill-local-variable (car setting))))
    (setq zk--document-settings nil)
    (when auto-save-default (auto-save-mode 1))))
(defun zk--document-changed ()
  (when (and (not zk-org-transaction-active) (zk-library-file-p buffer-file-name))
    (zk-library-notify (list buffer-file-name))))
;;;###autoload
(define-minor-mode zk-mode
  "Enable ZK's global Org presentation and knowledge-library workflow.
Completion, global keys and the default font remain user preferences."
  :global t :group 'zk
  (if zk-mode
      (progn
        (zk-org-enable)
        (zk--workflow-enable)
        (add-hook 'find-file-hook #'zk--document-enable)
        (add-hook 'after-save-hook #'zk--document-changed)
        (add-hook 'after-revert-hook #'zk--document-changed)
        (zk-home-start)
        (dolist (buffer (buffer-list)) (with-current-buffer buffer (zk--document-enable))))
    (remove-hook 'find-file-hook #'zk--document-enable)
    (remove-hook 'after-save-hook #'zk--document-changed)
    (remove-hook 'after-revert-hook #'zk--document-changed)
    (zk-home-stop)
    (zk--workflow-disable)
    (zk-org-disable)
    (dolist (buffer (buffer-list)) (with-current-buffer buffer (zk--document-disable)))))

(provide 'zk)
;;; zk.el ends here
