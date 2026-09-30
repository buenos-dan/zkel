;;; zk-notes-tests.el --- Notes checks -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(ert-deftest zk-note-extraction-preserves-links-and-leaves-inbox ()
  (zk-test-library
   (let* ((entry (zk-capture "Observation" "The useful idea."))
          (note (zk-inbox-to-note entry "A permanent idea.org")))
     (should-not (zk-inbox-entries))
     (should (equal (plist-get entry :id) (plist-get note :id)))
     (should (= 1 (length (zk-notes))))
     (zk-capture "Follow up" (format "See [[id:%s][Idea]]." (plist-get note :id)))
     (should (= 1 (length (zk-backlinks note)))))))

(ert-deftest zk-notes-exclude-workflow-files ()
  (zk-test-library
   (zk-capture "Inbox") (zk-test-project) (zk-note-create "Knowledge.org")
   (zk-test-write (zk-path "old.md") "# Existing markdown\n")
   (should (= 2 (length (zk-notes))))))
