;;; zk-org-tests.el --- Org checks -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(ert-deftest zk-transaction-rolls-back-both-documents ()
  (zk-test-library
   (zk-test-write (zk-inbox-path) "* Inbox\n")
   (zk-test-write (zk-agenda-path) "* Work\n")
   (should-error (zk-org-transaction (list (zk-inbox-path) (zk-agenda-path))
                                     (lambda ()
                                       (with-current-buffer (zk-org-buffer (zk-inbox-path))
                                         (insert "BROKEN"))
                                       (with-current-buffer (zk-org-buffer (zk-agenda-path))
                                         (insert "BROKEN"))
                                       (error "Stop"))))
   (dolist (file (list (zk-inbox-path) (zk-agenda-path)))
     (with-current-buffer (zk-org-buffer file)
       (should-not (string-match-p "BROKEN" (buffer-string)))))))

(ert-deftest zk-unsaved-edits-remain-unsaved ()
  (zk-test-library
   (let ((p (zk-test-project)) (e (zk-capture "Move")))
     (with-current-buffer (zk-org-buffer (zk-agenda-path))
       (goto-char (point-max)) (insert "Draft\n"))
     ;; Parent revision intentionally refreshed after editing its subtree.
     (setq p
           (car
            (seq-filter (lambda (x) (equal (plist-get x :title) "Ship prototype")) (zk-projects))))
     (let ((result (zk-inbox-process e p)))
       (should-not (plist-get result :saved))
       (with-temp-buffer
         (insert-file-contents (zk-agenda-path))
         (should-not (string-match-p "Draft" (buffer-string))))))))

(ert-deftest zk-sibling-edits-do-not-invalidate-an-id ()
  (zk-test-library
   (let ((task (zk-test-task)))
     (with-current-buffer (zk-org-buffer (zk-agenda-path))
       (goto-char (point-min)) (insert "#+title: Agenda\n"))
     (should (equal "NEXT" (plist-get (zk-task-update task :state "NEXT") :state))))))

(ert-deftest zk-stale-entry-is-rejected ()
  (zk-test-library
   (let ((task (zk-test-task)))
     (zk-task-update task :state "NEXT")
     (should-error (zk-task-update task :state "DONE") :type 'user-error))))

(ert-deftest zk-supports-file-level-org-ids ()
  (zk-test-library
   (let*
       ((file
         (zk-test-write (zk-path "old.org")
                        ":PROPERTIES:\n:ID: existing-id\n:END:\n#+title: Existing note\n* Content\nText\n"))
        (marker (zk-org-resolve "existing-id")))
     (should (= 1 (marker-position marker)))
     (should (equal file (buffer-file-name (marker-buffer marker))))
     (should (string-match-p "Content" (plist-get (zk-entry-read "existing-id") :body))))))

(ert-deftest zk-parent-ignores-escaped-commented-and-child-headings ()
  (zk-test-library
   (zk-test-write (zk-agenda-path)
                  "#+begin_src org\n,* Archive\n#+end_src\n* COMMENT Archive\n* Other\n** Archive\n* Archive       :ARCHIVE:\n")
   (with-current-buffer (zk-org-buffer (zk-agenda-path))
     (let ((parent (zk-org-ensure-container "Archive")))
       (goto-char parent)
       (should (= 1 (org-outline-level)))
       (should (member "ARCHIVE" (org-get-tags nil t)))))))
