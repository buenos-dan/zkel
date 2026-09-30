;;; zk-inbox-submit-tests.el --- Atomic edited and direct submissions -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(ert-deftest zk-inbox-submit-preserves-root-properties-and-literal-example-headings ()
  (zk-test-library
   (let* ((entry (zk-capture "Old" "Old body"))
          (text "New\n#+begin_example\n,* literal\n#+end_example\n* Real child\nText\n"))
     (with-current-buffer (zk-org-buffer (zk-inbox-path))
       (goto-char (zk-org-locate entry)) (org-entry-put nil "CUSTOM" "keep")
       (setq entry (zk-org-entry)))
     (let ((saved (zk-inbox-submit text :reference entry)))
       (should (equal (plist-get saved :id) (plist-get entry :id)))
       (with-current-buffer (zk-org-buffer (zk-inbox-path))
         (goto-char (zk-org-locate saved)) (should (equal (org-entry-get nil "CUSTOM") "keep")))
       (should (string-match-p "^,\\* literal" (plist-get (zk-entry-read saved) :body))))
     (should (equal text (zk-inbox-edit-text (car (zk-inbox-entries))))))))

(ert-deftest zk-inbox-submit-direct-event-and-project ()
  (zk-test-library
   (let ((event (zk-inbox-submit "Appointment\nLocation" :target 'agenda :kind 'event
                                 :destination '(:new-area "Life") :scheduled
                                 "2026-10-01 09:00-10:00")))
     (should-not (plist-get event :state))
     (should (plist-get event :scheduled)))
   (let ((project (zk-inbox-submit "Read a book" :target 'agenda :kind 'project
                                   :destination '(:new-area "Life"))))
     (should (equal "project" (plist-get project :type)))
     (should-not (plist-get project :state)))
   (should-not (file-exists-p (zk-inbox-path)))))

(ert-deftest zk-inbox-submit-keeps-existing-event-schedule ()
  (zk-test-library
   (let ((entry (zk-capture "Appointment")))
     (with-current-buffer (zk-org-buffer (zk-inbox-path))
       (goto-char (zk-org-locate entry)) (org-schedule nil "2026-10-01") (setq entry (zk-org-entry)))
     (let ((event (zk-inbox-submit (zk-inbox-edit-text entry) :reference entry
                                   :target 'agenda :kind 'event :destination '(:new-area "Life"))))
       (should (string-match-p "2026-10-01" (plist-get event :scheduled)))))))

(ert-deftest zk-inbox-submit-new-agenda-failure-leaves-no-capture-or-project ()
  (zk-test-library
   (cl-letf (((symbol-function 'zk-org-set-state) (lambda (&rest _) (error "Transition failed"))))
     (should-error (zk-inbox-submit "Action" :target 'agenda
                                    :destination '(:new-area "Work" :new-project "Project"))))
   (should-not (zk-inbox-entries)) (should-not (zk-tasks)) (should-not (zk-projects))
   (should-not (file-exists-p (zk-inbox-path)))
   (should-not (file-exists-p (zk-agenda-path)))))

(ert-deftest zk-inbox-workspace-save-error-does-not-repeat-committed-new-item ()
  (zk-test-library
   (zk-process-inbox) (zk-inbox-review-edit) (insert "Save failure")
   (cl-letf (((symbol-function 'save-buffer) (lambda (&rest _) (error "Disk unavailable"))))
     (let ((result (zk-inbox-review-apply)))
       (should result) (should-not (plist-get result :saved))
       (should (plist-get result :save-errors))))
   (should (string-empty-p (buffer-string)))
   (should-not (zk-inbox-review-apply))
   (with-current-buffer (zk-org-buffer (zk-inbox-path))
     (goto-char (point-min)) (should (re-search-forward "^\\*\\* Save failure" nil t))
     (should-not (re-search-forward "^\\*\\* Save failure" nil t)))))

(ert-deftest zk-inbox-home-entry-opens-organizer-and-no-capture-shortcut ()
  (zk-test-library
   (zk-capture "Organize this") (zk-home)
   (should-not (eq (key-binding "c") 'zk-inbox-capture))
   (should-not (string-match-p "Capture \\[c\\]" (buffer-string)))
   (goto-char (point-min)) (search-forward "Organize this")
   (button-activate (button-at (1- (point))))
   (should (eq major-mode 'zk-inbox-review-mode))
   (should (string-prefix-p "Organize this" (buffer-string)))
   (zk-inbox-review-quit)
   (goto-char (point-min)) (search-forward "Organize this")
   (zk-process-inbox)
   (should (eq zk-inbox-review--selected 'new))
   (should (string-empty-p (buffer-string)))))
