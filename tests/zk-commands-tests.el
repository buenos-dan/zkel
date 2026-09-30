;;; zk-commands-tests.el --- Commands checks -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(ert-deftest zk-find-note-matches-filenames-not-document-headings ()
  (zk-test-library
   (let
       ((target
         (zk-test-write (zk-path "org-notes/mac-configuration.org") "#+title: A different heading\n"))
        (completion-styles '(basic)) (completion-ignore-case nil)
        (completion-category-overrides '((zk-note-file (styles basic)))))
     (zk-test-write (zk-path "md-notes/another.md") "# mac inside content only\n")
     (cl-letf (((symbol-function 'zk-notes) (lambda () (error "Finder must not scan file content")))
               ((symbol-function 'completing-read)
                (lambda (_prompt table &rest _)
                  (dolist (query '("mac" "MAC" "configuration"))
                    (let ((matches (completion-all-completions query table nil (length query))))
                      (should
                       (equal "org-notes/mac-configuration.org"
                              (substring-no-properties (car matches))))
                      (should-not (consp (cdr matches)))))
                  "org-notes/mac-configuration.org")))
       (zk-find-note))
     (should (equal buffer-file-name target))
     (should (equal completion-styles '(basic)))
     (should-not completion-ignore-case))))

(ert-deftest zk-find-note-disambiguates-same-filename-and-chinese ()
  (zk-test-library
   (zk-test-write (zk-path "org-notes/topic.org") "#+title: One\n")
   (let ((target (zk-test-write (zk-path "org-notes/深度学习/topic.org") "#+title: Two\n")))
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt table &rest _)
                  (let ((matches (completion-all-completions "topic" table nil 5)))
                    (should (= 2 (length (seq-take matches 2)))))
                  (let ((matches (completion-all-completions "深度学习" table nil 4)))
                    (should
                     (equal "org-notes/深度学习/topic.org" (substring-no-properties (car matches)))))
                  "org-notes/深度学习/topic.org")))
       (should (equal target (zk-ui-read-note-file)))))))
