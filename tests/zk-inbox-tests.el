;;; zk-inbox-tests.el --- Inbox checks -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(ert-deftest zk-capture-is-raw-and-idempotent ()
  (zk-test-library
   (let ((result (zk-capture "An idea" "Source https://example.com" "request-1")))
     (should (plist-get result :id)) (should (plist-get result :saved))
     (should-not (plist-get result :state))
     (should (= 1 (length (zk-inbox-entries))))
     (zk-capture "An idea" nil "request-1")
     (should (= 1 (length (zk-inbox-entries))))
     (should-not (zk-tasks)))))

(ert-deftest zk-process-preserves-identity-body-and-project ()
  (zk-test-library
   (let* ((project (zk-test-project)) (entry (zk-capture "Read" "Preserve this paragraph."))
          (result (zk-inbox-process entry project :state "NEXT" :scheduled "2026-10-01")))
     (should-not (zk-inbox-entries))
     (should (equal (plist-get entry :id) (plist-get result :id)))
     (should (equal '("Work" "Ship prototype" "Read") (plist-get result :path)))
     (should (= 1 (length (zk-tasks "NEXT"))))
     (with-current-buffer (zk-org-buffer (zk-agenda-path))
       (should (string-match-p "Preserve this paragraph" (buffer-string)))))))

(ert-deftest zk-processing-invalid-date-does-not-move ()
  (zk-test-library
   (let ((p (zk-test-project)) (e (zk-capture "Keep me")))
     (should-error (zk-inbox-process e p :scheduled "2026-02-30") :type 'user-error)
     (should-error (zk-inbox-process e p :kind 'event) :type 'user-error)
     (should (= 1 (length (zk-inbox-entries)))))))

(ert-deftest zk-archive-is-recoverable-and-excluded ()
  (zk-test-library
   (let ((entry (zk-capture "Old idea" "History")))
     (zk-inbox-archive entry)
     (should-not (zk-inbox-entries))
     (should-not (zk-tasks))
     (should (markerp (zk-org-resolve (plist-get entry :id)))))))

(ert-deftest zk-processing-failure-restores-subtrees ()
  (zk-test-library
   (let* ((project (zk-test-project)) (entry (zk-capture "Do not lose me" "Body"))
          (before-inbox (with-current-buffer (zk-org-buffer (zk-inbox-path)) (buffer-string)))
          (before-agenda (with-current-buffer (zk-org-buffer (zk-agenda-path)) (buffer-string))))
     (cl-letf
         (((symbol-function 'zk-org-set-dates)
           (lambda (&rest _) (error "Injected failure after paste"))))
       (should-error (zk-inbox-process entry project :state "NEXT")))
     (should
      (equal before-inbox (with-current-buffer (zk-org-buffer (zk-inbox-path)) (buffer-string))))
     (should
      (equal before-agenda (with-current-buffer (zk-org-buffer (zk-agenda-path)) (buffer-string)))))))

(ert-deftest zk-capture-metadata-uses-recorded-dates ()
  (zk-test-library
   (zk-test-write (zk-inbox-path)
                  "* Inbox\n** Legacy capture\n:PROPERTIES:\n:ZK_ORIGIN: Learning\n:END:\nCaptured: [2025-12-17 Wed 14:53]\n")
   (let ((entry (car (zk-inbox-entries))))
     (should (equal "Learning" (plist-get entry :origin)))
     (should (equal "[2025-12-17 Wed 14:53]" (plist-get entry :created))))))

(ert-deftest zk-archive-reuses-tagged-parent-repeatedly ()
  (zk-test-library
   (zk-test-write (zk-agenda-path)
                  "* Archive                    :history:ARCHIVE:\n** Existing\nKeep this body\n")
   (let (ids)
     (dolist (title '("One" "Two" "Three"))
       (let ((entry (zk-capture title (concat "Body of " title))))
         (push (plist-get entry :id) ids)
         (zk-inbox-archive entry)))
     (with-current-buffer (zk-org-buffer (zk-agenda-path))
       (let ((parents (org-element-map (org-element-parse-buffer 'headline) 'headline
                                       (lambda (h) (when (= 1 (org-element-property :level h)) h)))))
         (should (= 1 (length parents)))
         (goto-char (org-element-property :begin (car parents)))
         (should (member "history" (org-get-tags nil t)))
         (should (member "ARCHIVE" (org-get-tags nil t))))
       (should (string-match-p "Keep this body" (buffer-string))))
     (dolist (id ids)
       (let ((marker (zk-org-resolve id)))
         (with-current-buffer (marker-buffer marker)
           (goto-char marker)
           (should (equal '("Archive") (org-get-outline-path)))
           (should (org-in-archived-heading-p))))))
   (should-not (zk-inbox-entries))
   (should-not (zk-tasks))))
