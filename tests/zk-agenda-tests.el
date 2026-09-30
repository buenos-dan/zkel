;;; zk-agenda-tests.el --- Agenda checks -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(ert-deftest zk-calendar-retains-completed-items-and-follows-visibility-changes ()
  (zk-test-library
   (let ((date (format-time-string "%Y-%m-%d %a"))
         (org-agenda-skip-scheduled-if-done nil)
         (org-agenda-skip-deadline-if-done nil)
         (org-agenda-skip-timestamp-if-done nil))
     (zk-test-write (zk-agenda-path)
                    (format (concat "* Life\n** DONE Finished appointment\nSCHEDULED: <%s 09:00>\n"
                                    "** DONE Finished deadline\nDEADLINE: <%s>\n"
                                    "** DONE Finished event\n<%s 11:00>\n") date date date))
     (let ((items (zk-today-items)))
       (dolist (title '("Finished appointment" "Finished deadline" "Finished event"))
         (should (seq-some (lambda (item) (equal title (plist-get item :title))) items))))
     (should-not (zk-tasks "NEXT"))
     ;; A change in visibility must invalidate the cached calendar immediately.
     (setq org-agenda-skip-scheduled-if-done t
           org-agenda-skip-deadline-if-done t org-agenda-skip-timestamp-if-done t)
     (should-not (zk-today-items))
     (setq org-agenda-skip-scheduled-if-done nil
           org-agenda-skip-deadline-if-done nil org-agenda-skip-timestamp-if-done nil)
     (dolist (week '(nil t))
       (zk-agenda-view week)
       (dolist (title '("Finished appointment" "Finished deadline" "Finished event"))
         (should (string-match-p title (buffer-string)))))
     (should (= 3 (length (zk-today-items)))))))

(ert-deftest zk-calendar-includes-no-state-events ()
  (zk-test-library
   (zk-test-write (zk-agenda-path)
                  (format
                   "* Calendar\n** Meeting\nSCHEDULED: <%s 16:00-17:00>\n** TODO Task\nSCHEDULED: <%s>\n"
                   (format-time-string "%Y-%m-%d %a") (format-time-string "%Y-%m-%d %a")))
   (let ((buffer (current-buffer)) (items (zk-today-items)))
     (should (eq buffer (current-buffer)))
     (should (seq-some (lambda (x) (string-match-p "Meeting" (plist-get x :text))) items)))))

(ert-deftest zk-agenda-views-do-not-count-archives-or-inbox-as-next ()
  (zk-test-library
   (zk-test-write (zk-inbox-path) "* Inbox\n** NEXT Unprocessed legacy title\n")
   (zk-test-write (zk-agenda-path) "* Work\n** NEXT Active\n* Archive :ARCHIVE:\n** NEXT Hidden\n")
   (should (= 1 (length (zk-tasks "NEXT"))))
   (should (equal "Active" (plist-get (car (zk-tasks "NEXT")) :title)))))

(ert-deftest zk-calendar-keeps-native-date-grid-and-faces ()
  (zk-test-library
   (zk-test-write (zk-agenda-path)
                  (format "* Calendar\n** Meeting\nSCHEDULED: <%s 16:00-17:00>\n"
                          (format-time-string "%Y-%m-%d %a")))
   (let* ((origin (current-buffer))
          (org-agenda-time-grid
           '((daily today require-timed) (800 1200 1600 2000) "......" "----------------"))
          (rows (zk-agenda-day-rows 100))
          (date (seq-find (lambda (row) (eq (plist-get row :kind) 'date)) rows)))
     (should (eq origin (current-buffer)))
     (should (equal 'org-agenda-date-today (get-text-property 0 'face (plist-get date :text))))
     (should (seq-some (lambda (row) (string-match-p "8:00" (plist-get row :text))) rows))
     (should
      (seq-some (lambda (row) (string-match-p "16:00-17:00.*Meeting" (plist-get row :text))) rows))
     (should (= 1 (length (zk-today-items))))
     (should-not (seq-some (lambda (row) (get-text-property 0 'keymap (plist-get row :text))) rows)))))

(ert-deftest zk-empty-calendar-still-shows-a-day ()
  (zk-test-library
   (let ((rows (zk-agenda-day-rows)))
     (should (seq-some (lambda (row) (eq (plist-get row :kind) 'date)) rows))
     (should (seq-some (lambda (row) (eq (plist-get row :kind) 'grid)) rows))
     (should-not (zk-today-items)))))

(ert-deftest zk-calendar-is-not-truncated-by-dashboard-preview-limit ()
  (zk-test-library
   (zk-test-write (zk-agenda-path)
                  (concat "* Calendar\n"
                          (mapconcat (lambda (n) (format "** Meeting %d\nSCHEDULED: <%s %02d:00>\n"
                                                         n (format-time-string "%Y-%m-%d %a")
                                                         (+ n 8)))
                                     '(0 1 2 3 4 5 6) "")))
   (let ((zk-home-item-limit 1))
     (zk-home)
     (dolist (n '(0 1 2 3 4 5 6))
       (goto-char (point-min))
       (search-forward (format "Meeting %d" n))
       (should (button-at (1- (point))))
       (should (get-text-property (1- (point)) 'face)))
     (goto-char (point-min)) (search-forward "Meeting 6")
     (let ((entry (get-text-property (1- (point)) 'zk-entry)))
       (should (plist-get entry :revision))
       (should (markerp (zk-org-resolve entry)))))))
