;;; zk-record-tests.el --- Record identity and navigation -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(ert-deftest zk-record-navigation-allows-stale-snapshot-but-writes-reject-it ()
  (zk-test-library
   (let ((task (zk-test-task "NEXT" "Original")))
     (with-current-buffer (zk-org-buffer (zk-agenda-path))
       (goto-char (zk-org-locate task))
       (org-edit-headline "Changed"))
     (save-window-excursion
       (zk-ui-open task)
       (should (equal "Changed" (org-get-heading t t t t))))
     (should-error (zk-task-update task :state "DONE") :type 'user-error))))

(ert-deftest zk-record-note-create-and-list-have-the-same-file-contract ()
  (zk-test-library
   (let* ((created (zk-note-create "知识.org" "Body")) (listed (car (zk-notes))))
     (dolist (key '(:record :scope :file :filename :title :id :revision :position))
       (should (equal (plist-get created key) (plist-get listed key)))))
   (let* ((note (car (zk-notes))) (body (plist-get (zk-entry-read note) :body)))
     (should (eq (plist-get note :record) 'note))
     (should (eq (plist-get note :scope) 'file))
     (should (string-prefix-p ":PROPERTIES:" body))
     (should (string-match-p "Body" body))
     (save-window-excursion
       (zk-ui-open note)
       (should (equal buffer-file-name (plist-get note :file)))))))

(ert-deftest zk-record-note-id-never-comes-from-an-unrelated-later-heading ()
  (zk-test-library
   (let ((file (zk-test-write (zk-path "notes/source.org")
                              "#+title: Document\n* First\nBody\n* Second\n:PROPERTIES:\n:ID: unrelated\n:END:\n")))
     (should-not (plist-get (zk-note-metadata file) :id)))))

(ert-deftest zk-record-file-id-takes-precedence-over-heading-id ()
  (zk-test-library
   (let ((file (zk-test-write (zk-path "notes/source.org")
                              ":PROPERTIES:\n:ID: file-id\n:END:\n#+title: Document\n* Root\n:PROPERTIES:\n:ID: heading-id\n:END:\n")))
     (should (equal "file-id" (plist-get (zk-note-metadata file) :id))))))

(ert-deftest zk-record-markdown-read-preserves-its-major-mode ()
  (zk-test-library
   (let* ((file (zk-test-write (zk-path "notes/source.md") "# Markdown\nBody\n"))
          (note (zk-note-metadata file))
          (buffer (find-file-noselect file))
          (mode (buffer-local-value 'major-mode buffer)))
     (should (string-prefix-p "# Markdown" (plist-get (zk-entry-read note) :body)))
     (should (eq mode (buffer-local-value 'major-mode buffer))))))

(ert-deftest zk-record-all-inbox-outcomes-reject-container-and-child-input ()
  (zk-test-library
   (let* ((capture (zk-capture "Parent" "*** Child\n"))
          (project (zk-test-project)) child)
     (with-current-buffer (zk-org-buffer (zk-inbox-path))
       (goto-char (zk-org-locate capture))
       (re-search-forward "^\\*\\*\\* Child")
       (setq child (zk-org-entry)))
     (dolist (reference (list child
                              (with-current-buffer (zk-org-buffer (zk-inbox-path))
                                (goto-char (point-min)) (re-search-forward "^\\* Inbox")
                                (zk-org-entry))))
       (should-error (zk-inbox-process reference project) :type 'user-error)
       (should-error (zk-inbox-to-note reference "Invalid.org") :type 'user-error)
       (should-error (zk-inbox-archive reference) :type 'user-error))
     (should (= 1 (length (zk-inbox-entries)))))))

(ert-deftest zk-record-state-configuration-drives-query-and-transition ()
  (zk-test-library
   (let* ((zk-org-todo-keywords '(sequence "TODO(t)" "NEXT(n)" "BLOCKED(b)" "|" "DONE(d)"))
          (task (zk-test-task)))
     (should (member "BLOCKED" (zk-org-states)))
     (should (equal '("DONE") (zk-org-states 'done)))
     (zk-task-update task :state "BLOCKED")
     (should (= 1 (length (zk-tasks "BLOCKED")))))))
