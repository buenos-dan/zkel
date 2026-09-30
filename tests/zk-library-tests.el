;;; zk-library-tests.el --- Library checks -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(ert-deftest zk-notifications-cannot-turn-success-into-failure ()
  (zk-test-library
   (let ((zk-change-hook (list (lambda (_) (error "Display unavailable")))))
     (should (plist-get (zk-capture "Saved despite display") :saved))
     (should (= 1 (length (zk-inbox-entries)))))))
