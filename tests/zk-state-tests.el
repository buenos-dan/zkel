;;; zk-state-tests.el --- Three-state workflow -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(ert-deftest zk-state-defaults-and-native-keys-are-todo-next-done ()
  (should (equal '("TODO" "NEXT" "DONE") (zk-org-states)))
  (should (equal '("TODO" "NEXT") (zk-org-states 'active)))
  (should (equal '("DONE") (zk-org-states 'done)))
  (with-temp-buffer
    (let ((org-todo-keywords (list zk-org-todo-keywords)))
      (org-mode)
      (dolist (pair '(("TODO" . ?t) ("NEXT" . ?n) ("DONE" . ?d)))
        (should (equal (cdr pair) (cdr (assoc (car pair) org-todo-key-alist)))))
      (dolist (state '("WAIT" "HOLD" "CANCELLED"))
        (should-not (assoc state org-todo-key-alist))))))

(ert-deftest zk-state-workflow-rejects-retired-states-without-moving-inbox ()
  (zk-test-library
   (let ((task (zk-test-task)) (entry (zk-capture "Raw")) (project (car (zk-projects))))
     (dolist (state '("WAIT" "HOLD" "CANCELLED"))
       (should-error (zk-task-update task :state state) :type 'user-error)
       (should-error (zk-inbox-process entry project :state state) :type 'user-error))
     (should (= 1 (length (zk-inbox-entries))))
     (should (= 1 (length (zk-tasks "TODO")))))))

(ert-deftest zk-state-inbox-chooser-has-only-active-states ()
  (zk-test-library
   (zk-process-inbox)
   (cl-letf (((symbol-function 'completing-read)
              (lambda (_prompt choices &rest _)
                (should (equal '("TODO" "NEXT") choices))
                "NEXT")))
     (zk-inbox-review-state))
   (should (equal "NEXT" (plist-get (zk-inbox-review--draft) :state)))))
