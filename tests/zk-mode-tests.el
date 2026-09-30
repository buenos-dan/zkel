;;; zk-mode-tests.el --- Mode checks -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(ert-deftest zk-load-is-passive ()
  (should-not zk-mode)
  (should-not (memq 'zk--document-enable find-file-hook))
  (should-not (eq initial-buffer-choice 'zk-home)))

(ert-deftest zk-mode-is-local-and-reversible ()
  (zk-test-library
   (let ((keywords org-todo-keywords) (styles completion-styles) (initial initial-buffer-choice))
     (unwind-protect
         (progn
           (zk-mode 1)
           (with-current-buffer (zk-org-buffer (zk-inbox-path))
             (should-not make-backup-files) (should-not auto-save-default))
           (should (equal styles completion-styles))
           (should (equal initial initial-buffer-choice)))
       (zk-mode -1))
     (should (equal keywords org-todo-keywords)))))
