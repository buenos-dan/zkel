;;; zk-tasks-tests.el --- Tasks checks -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(ert-deftest zk-repeating-next-uses-org-transition ()
  (zk-test-library
   (let* ((task (zk-test-task "NEXT"))
          (dated (zk-task-update task :scheduled "2026-09-30 09:00-10:00 +1w")))
     (should (string-match-p (regexp-quote "09:00-10:00 +1w") (plist-get dated :scheduled)))
     (zk-task-update dated :state "DONE")
     (should (= 1 (length (zk-tasks))))
     (should (string-match-p "2026-10-07" (plist-get (car (zk-tasks)) :scheduled))))))
