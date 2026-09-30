;;; zk-org-display-tests.el --- Global Org ownership and lifecycle -*- lexical-binding: t; -*-
(require 'zk-test-helper)

(defmacro zk-test-org-profile (&rest body)
  (declare (indent 0))
  `(zk-test-library
    (unwind-protect (progn ,@body) (zk-mode -1))))

(ert-deftest zk-org-profile-applies-outside-library-without-editing-or-unfolding ()
  (zk-test-org-profile
    (with-temp-buffer
      (insert "#+STARTUP: showstars\n* Heading\nBody\n** Child\nText\n")
      (org-mode)
      (setq-local org-ellipsis "~" org-indent-indentation-per-level 4)
      (goto-char (point-min)) (re-search-forward "^\\* Heading") (beginning-of-line)
      (org-fold-hide-subtree)
      (let ((text (buffer-string)) (tick (buffer-chars-modified-tick))
            (point-before (point)) (modified (buffer-modified-p))
            (child (save-excursion (search-forward "Child") (1- (point)))))
        (should (org-invisible-p child))
        (zk-mode 1)
        (should org-indent-mode)
        (should (= 2 org-indent-indentation-per-level))
        (should org-hide-leading-stars)
        (should (equal "…" org-ellipsis))
        (should (org-invisible-p child))
        (should (= tick (buffer-chars-modified-tick)))
        (should (= point-before (point)))
        (should (eq modified (buffer-modified-p)))
        (should (equal (substring-no-properties text) (buffer-substring-no-properties (point-min) (point-max))))
        (org-set-regexps-and-options)
        (should org-hide-leading-stars)
        (zk-mode -1)
        (should-not org-indent-mode)
        (should (equal "~" org-ellipsis))
        (should (= 4 org-indent-indentation-per-level))
        (should (org-invisible-p child))
        (should (= tick (buffer-chars-modified-tick)))))))

(ert-deftest zk-org-profile-new-buffer-defaults-and-file-overrides ()
  (zk-test-org-profile
    (zk-mode 1)
    (with-temp-buffer
      (org-mode)
      (should org-indent-mode)
      (should org-startup-with-inline-images)
      (should (member "NEXT" org-todo-keywords-1))
      (should (equal "…" (org-fold-core-get-folding-spec-property 'outline :ellipsis))))
    (with-temp-buffer
      (insert "#+TODO: OPEN | CLOSED\n#+STARTUP: noinlineimages showstars\n* OPEN Item\n")
      (org-mode)
      (should (member "OPEN" org-todo-keywords-1))
      (should-not org-startup-with-inline-images)
      (should org-hide-leading-stars))))

(ert-deftest zk-org-profile-restores-global-settings-faces-and-library-paths ()
  (zk-test-org-profile
    (let* ((symbols '(org-startup-indented org-hide-leading-stars org-ellipsis
                     org-startup-with-inline-images org-todo-keywords org-todo-keyword-faces
                     org-log-done org-log-repeat
                     org-agenda-skip-scheduled-if-done org-agenda-skip-deadline-if-done
                     org-agenda-skip-timestamp-if-done org-agenda-files org-default-notes-file remember-data-file))
           (before (mapcar (lambda (s) (cons s (copy-tree (default-value s)))) symbols))
           (faces (mapcar (lambda (s) (cons s (get s 'face-override-spec))) '(org-todo org-done org-agenda-done))))
      (dotimes (_ 2)
        (zk-mode 1)
        (should (equal (list (zk-agenda-path)) (default-value 'org-agenda-files)))
        (should (equal (zk-inbox-path) (default-value 'org-default-notes-file)))
        (should (equal (zk-inbox-path) (default-value 'remember-data-file)))
        (should (equal 'zk-org-todo (alist-get "TODO" (default-value 'org-todo-keyword-faces) nil nil #'equal)))
        (should (equal 'zk-org-next (alist-get "NEXT" (default-value 'org-todo-keyword-faces) nil nil #'equal)))
        (should-not org-agenda-skip-scheduled-if-done)
        (should-not org-agenda-skip-deadline-if-done)
        (should-not org-agenda-skip-timestamp-if-done)
        (should (eq 'time org-log-done))
        (should (eq 'time org-log-repeat))
        (zk-mode -1)
        (dolist (pair before) (should (equal (cdr pair) (default-value (car pair)))))
        (dolist (pair faces) (should (equal (cdr pair) (get (car pair) 'face-override-spec))))))))

(ert-deftest zk-org-profile-enable-is-idempotent-and-disable-removes-hooks ()
  (zk-test-org-profile
    (with-temp-buffer
      (org-mode)
      (zk-mode 1)
      (let ((state zk-org--buffer-state) (defaults zk-org--defaults))
        (zk-mode 1) (zk-mode 1)
        (zk-org--display) (zk-org--display)
        (should (eq state zk-org--buffer-state))
        (should (eq defaults zk-org--defaults))
        (should (= 1 (cl-count #'zk-org--display org-mode-hook)))
        (should (= 1 (cl-count (current-buffer) org-indent-agentized-buffers)))
        (let ((count 0))
          (advice-mapc (lambda (_ properties)
                         (when (eq (plist-get properties :name) 'zk-org--outline-options)
                           (cl-incf count))) 'org-set-regexps-and-options)
          (should (advice-member-p #'zk-org--outline-options 'org-set-regexps-and-options))))
      (zk-mode -1)
      (should-not (memq #'zk-org--display org-mode-hook))
      (should-not (advice-member-p #'zk-org--prepare 'org-set-regexps-and-options))
      (should-not (advice-member-p #'zk-org--outline-options 'org-set-regexps-and-options))
      (should-not zk-org--buffer-state))))

(ert-deftest zk-org-profile-does-not-revert-later-global-user-preferences ()
  (let ((original (default-value 'org-ellipsis))
        (original-path (default-value 'org-default-notes-file)))
    (unwind-protect
        (zk-test-org-profile
          (zk-mode 1)
          (setq-default org-ellipsis "changed-later" org-default-notes-file "/tmp/changed-later.org")
          (zk-mode -1)
          (should (equal "changed-later" (default-value 'org-ellipsis)))
          (should (equal "/tmp/changed-later.org" (default-value 'org-default-notes-file))))
      (setq-default org-ellipsis original org-default-notes-file original-path))))

(ert-deftest zk-org-profile-keeps-fonts-and-other-major-modes ()
  (zk-test-org-profile
    (with-temp-buffer
      (text-mode)
      (let ((font (face-all-attributes 'default)) (settings (buffer-local-variables)))
        (zk-mode 1)
        (should (eq major-mode 'text-mode))
        (should-not zk-org--buffer-state)
        (should (equal settings (buffer-local-variables)))
        (should (equal font (face-all-attributes 'default)))))))

(ert-deftest zk-org-profile-respects-later-local-preferences ()
  (zk-test-org-profile
    (with-temp-buffer
      (org-mode) (zk-mode 1)
      (setq-local org-ellipsis "local-choice" indent-tabs-mode t)
      (zk-mode -1)
      (should (equal "local-choice" org-ellipsis))
      (should indent-tabs-mode))))

(ert-deftest zk-org-profile-restores-existing-indent-mode-settings ()
  (zk-test-org-profile
    (with-temp-buffer
      (org-mode) (org-indent-mode 1)
      (setq-local org-indent-indentation-per-level 4 org-adapt-indentation 'headline-data)
      (zk-mode 1) (should (= 2 org-indent-indentation-per-level))
      (zk-mode -1)
      (should org-indent-mode)
      (should (= 4 org-indent-indentation-per-level))
      (should (eq 'headline-data org-adapt-indentation)))))

(ert-deftest zk-org-profile-preserves-preexisting-inline-images ()
  (zk-test-org-profile
    (with-temp-buffer
      (insert "Image\n") (org-mode)
      (let ((existing (make-overlay 1 2)) created)
        (setq org-inline-image-overlays (list existing))
        (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
                  ((symbol-function 'zk-org--show-images)
                   (lambda (&rest _) (unless created
                                       (setq created (make-overlay 2 3))
                                       (push created org-inline-image-overlays)))))
          (zk-mode 1))
        (should (overlay-buffer existing))
        (should (overlay-buffer created))
        (zk-mode -1)
        (should (overlay-buffer existing))
        (should-not (overlay-buffer created))
        (should (equal (list existing) org-inline-image-overlays))))))

(ert-deftest zk-org-profile-preserves-inbox-editor-drafts ()
  (zk-test-org-profile
    (zk-process-inbox)
    (zk-inbox-review-edit)
    (insert "Unsaved thought\nDetails")
    (let ((text (buffer-string)) (draft (copy-tree (zk-inbox-review--draft)))
          (position (point)) (tick (buffer-chars-modified-tick)))
      (zk-mode 1)
      (should (= tick (buffer-chars-modified-tick)))
      (should (= position (point)))
      (should (equal (substring-no-properties text) (buffer-substring-no-properties (point-min) (point-max))))
      (should (equal draft (zk-inbox-review--draft)))
      (should (buffer-modified-p)))))
