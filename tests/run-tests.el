;;; run-tests.el --- Batch test entry point -*- lexical-binding: t; -*-
(let* ((directory (file-name-directory (or load-file-name buffer-file-name)))
       (root (file-name-directory (directory-file-name directory))))
  (add-to-list 'load-path root)
  (add-to-list 'load-path directory)
  (dolist (file (directory-files directory t "\\`zk-.*-tests\\.el\\'")) (load file nil t)))
(ert-run-tests-batch-and-exit)
